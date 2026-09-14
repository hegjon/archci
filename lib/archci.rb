# frozen_string_literal: true

# archci.rb -- shared helpers for the ruby parts of archci (scan, top).
# Mirrors archci-common.sh: same config file, same job file format.
require 'etc'
require 'set'
require 'socket'
require 'json'
require 'open3'
require 'time'

module Archci
  CONF = ENV.fetch('ARCHCI_CONF', '/etc/archci/archci.conf')
  # The heartbeat's stats (the same two lists as archci-common.sh): the host's
  # and the job's, kept with the job file by archci-job heartbeat.
  HOST_STATS = %w[load mem disk cpus vendor archci].freeze
  JOB_STATS = %w[cpu_us cpu_dt rss peak build phase].freeze

  DEFAULTS = {
    'ARCHCI_HOME' => '/var/lib/archci',
    'ARCHCI_ARCH' => Etc.uname[:machine],
    'ARCHCI_PKGBUILDS_URL' => 'https://github.com/hegjon/omarchy-pkgs.git',
    'ARCHCI_PKGBUILDS_BRANCH' => 'core+extra',
    'ARCHCI_PKGBUILDS_DIR' => 'pkgbuilds',
    'ARCHCI_REPO' => 'omarchy',
    'ARCHCI_PKG_SOURCES' => '',
    'ARCHCI_PKG_REPOS' => '',
    'ARCHCI_PKG_ALSO' => '',
    'ARCHCI_IGNOREARCH' => '1',
    'ARCHCI_MAX_ATTEMPTS' => '3',
    'ARCHCI_RELEASE_LAG_MINUTES' => '20',
    'ARCHCI_SOURCES_REQUIRED' => '0',
    'ARCHCI_REMOTE_JOURNAL' => '/var/lib/archci/journal'
  }.freeze

  ROOT = File.expand_path('..', __dir__)

  QUEUES = %w[pending running done failed].freeze

  # Config file values, overridden by anything ARCHCI_* in the environment.
  def self.config
    @config ||= begin
      cfg = DEFAULTS.dup
      if File.readable?(CONF)
        File.foreach(CONF) do |line|
          next unless (m = line.match(/\A([A-Z][A-Z0-9_]*)=(.*)\z/m))

          cfg[m[1]] = unquote(m[2].strip)
        end
      end
      ENV.each { |k, v| cfg[k] = v if k.start_with?('ARCHCI_') }
      cfg
    end
  end

  def self.unquote(value)
    value.sub(/\s+#.*\z/, '').strip.sub(/\A(["'])(.*)\1\z/, '\2')
  end

  def self.home
    config['ARCHCI_HOME']
  end

  def self.queue(name)
    File.join(home, 'queue', name)
  end

  # A job file is key=value lines; unknown keys are kept so nothing is lost.
  def self.read_job(path)
    job = { 'path' => path }
    File.foreach(path) do |line|
      next unless (m = line.match(/\A([a-z_]+)=(.*)\z/m))

      job[m[1]] = m[2].chomp
    end
    job['attempt'] = job.fetch('attempt', '0').to_i
    job['mtime'] = File.mtime(path)
    job
  rescue Errno::ENOENT
    nil # raced with a claim/report, ignore
  end

  # newest: read only that many, the most recently written (a stat each,
  # not a read, decides which; done/ holds a month of jobs)
  def self.jobs(queue_name, newest: nil)
    paths = Dir.glob(File.join(queue(queue_name), '*.job'))
    paths = paths.sort_by { |p| -File.mtime(p).to_f }.first(newest) if newest
    paths.sort.filter_map { |p| read_job(p) }
  end

  # A built record ("version commit [arches]") by path, cached by the file's
  # mtime: archci top asks for every package's on every frame, and a stat is
  # cheaper than a read. nil when there is none.
  @built = {}
  def self.built_record(path)
    mtime = File.mtime(path)
    hit = @built[path]
    return hit[1] if hit && hit[0] == mtime

    (@built[path] = [mtime, File.read(path).split])[1]
  rescue Errno::ENOENT
    @built.delete(path)
    nil
  end

  # Arches the master builds for, and the arch whose workers build "any"
  # packages (pooled for every arch).
  def self.arches
    (config['ARCHCI_ARCHES'] || config['ARCHCI_ARCH']).split
  end

  def self.any_arch
    config['ARCHCI_ANY_ARCH'] || arches.first
  end

  # What the signer has released, as archci-signer-status last listed it
  # (released/<repo>-<arch>: "name version" per package the arch's database
  # names; released/<repo>-src: the source packages found): a Set of the
  # lines, nil without a listing (no signer status yet), cached by the
  # file's mtime.
  @released = {}
  def self.released(repo, arch)
    path = File.join(home, 'released', "#{repo}-#{arch}")
    mtime = File.mtime(path)
    hit = @released[path]
    return hit[1] if hit && hit[0] == mtime

    (@released[path] = [mtime, File.readlines(path, chomp: true).to_set])[1]
  rescue Errno::ENOENT
    @released.delete(path)
    nil
  end

  # Is what a built record says released? By the listing when there is
  # one; without one, by age: ARCHCI_RELEASE_LAG_MINUTES since the record.
  #   entry: what to look for in the listing
  def self.released?(repo, arch, entry, record_path)
    listing = released(repo, arch)
    return listing.include?(entry) if listing

    File.mtime(record_path) <= Time.now - config['ARCHCI_RELEASE_LAG_MINUTES'].to_i * 60
  end

  # The source package the sourcer made for pkg at its current commit, by
  # name, once the signer has released it (released?; a build claim hands it
  # to the worker); nil before that. The src built record is "version
  # commit file".
  def self.source_file(repo, pkg)
    path = File.join(home, 'built', "#{repo}-src", pkg['pkgbase'])
    _version, commit, file = built_record(path) || []
    return nil unless file && commit == pkg['commit']

    released?(repo, 'src', file, path) ? file : nil
  rescue Errno::ENOENT
    nil
  end

  # A worker id is <host>-<n> for a worker building the host's native arch
  # and <host>-<arch>-<n> for one emulating a port arch (archci-worker's
  # rule): the host and the port arch, nil for native.
  def self.worker_host(worker)
    if (m = worker.match(/\A(.+)-(#{Regexp.union(arches)})-\d+\z/))
      [m[1], m[2]]
    elsif (m = worker.match(/\A(.+)-\d+\z/))
      [m[1], nil]
    else
      [worker, nil]
    end
  end

  # One entry per host seen among RUNNING and RECENT jobs and the workers'
  # POLLS (hosts/<worker>, written by every claim and by archci-job poll),
  # from the newest stats any of its workers sent: a running job's heartbeat,
  # an idle worker's poll, or the last beat a finished job kept. A worker
  # whose last poll is older than POLL_TTL is gone. The native arch is what a
  # worker without an arch in its name builds ("any" jobs are the any
  # arch's). The sourcer claims and runs src jobs: a worker of the src arch,
  # counted as one. Order: the master, the sourcers, then the workers by name.
  POLL_TTL = 600

  def self.hosts(running, recent, polls, now)
    hosts = {}
    seen = running.map { |j| [j, now - j['heartbeat_age_s'], true] } +
           recent.map { |j| [j, (j['heartbeat'] && Time.iso8601(j['heartbeat'])), false] } +
           polls.map { |p| [p, (p['seen'] && Time.iso8601(p['seen'])), false] }
    # a worker counts while it was heard from within POLL_TTL: a running job,
    # a finished job's last heartbeat, or an idle poll (a stopped worker
    # drops out after that; the recent list alone kept it for 50 jobs)
    seen = seen.reject { |j, t, running_now| !running_now && (t.nil? || now - t > POLL_TTL) }
    seen.each do |j, beat, running_now|
      next unless j['worker']

      host, port = worker_host(j['worker'])
      h = hosts[host] ||= { 'host' => host, 'workers' => [], 'building' => 0, 'arch' => nil, 'heartbeat_age_s' => nil,
                            **HOST_STATS.to_h { |k| [k, nil] } }
      h['sourcer'] = true if j['arch'] == 'src'
      h['workers'] |= [j['worker']]
      h['building'] += 1 if running_now
      h['arch'] ||= (j['arch'] == 'any' ? any_arch : j['arch']) unless port
      h['vendor'] ||= j['vendor']   # constant for a host: any worker that sent it will do
      # the archci version: from the newest beat that carries one (an idle
      # poll and a heartbeat both do; a finished job's record may not)
      if j['archci'] && beat && (h['archci_at'].nil? || beat > h['archci_at'])
        h['archci'] = j['archci']
        h['archci_at'] = beat
      end
      next unless beat && j['load'] && (h['heartbeat_age_s'].nil? || now - beat < h['heartbeat_age_s'])

      h.merge!('heartbeat_age_s' => (now - beat).to_i, **j.slice(*(HOST_STATS - ['archci'])).compact)
    end
    # this machine, the master, first: its own stats right now (the same
    # function the workers report with), whether or not it runs workers
    master = Socket.gethostname.split('.').first
    m = hosts[master] ||= { 'host' => master, 'workers' => [], 'building' => 0, 'arch' => nil, 'heartbeat_age_s' => nil,
                            **HOST_STATS.to_h { |k| [k, nil] } }
    m['arch'] ||= Etc.uname[:machine]
    m.merge!('heartbeat_age_s' => 0, **master_stats)
    # the master first, then the sourcer(s), then the workers by name
    rest = hosts.values.reject { |h| h.equal?(m) }.sort_by { |h| [h['sourcer'] ? 0 : 1, h['host']] }
    [m, *rest].each { |h| h['workers'].sort!; h.delete('archci_at'); h.delete('sourcer') }
  end

  # The master's own host stats, as a worker would send them (load, mem, disk
  # of ARCHCI_HOME, cpus, vendor, archci), from lib/archci-common.sh.
  def self.master_stats
    out, status = Open3.capture2('bash', '-c', 'source "$1/lib/archci-common.sh"; archci_worker_stats "$ARCHCI_HOME"', '_', ROOT)
    return {} unless status.success?

    out.split.to_h { |kv| kv.split('=', 2) }.slice(*HOST_STATS)
  end

  # The packages in the PKGBUILD repository clone, from archci-pkgindex (which
  # caches them per clone HEAD): name (the job's pkgbase), version, commit,
  # arches, profile, source and whether package.json skips the build. Empty
  # when the clone does not exist yet (archci-scan creates it).
  def self.packages(refresh: false)
    @packages = nil if refresh
    @packages ||= begin
      out, status = Open3.capture2(File.join(ROOT, 'master', 'archci-pkgindex'))
      if status.success?
        out.lines.filter_map do |line|
          name, version, commit, arch, profile, source, build, arch_repo, pkgnames, deps = line.split
          next unless build

          { 'pkgbase' => name, 'version' => version, 'commit' => commit, 'arches' => arch.split(','),
            'profile' => profile, 'source' => source, 'skip' => build == 'skip', 'network' => (build if %w[network loopback].include?(build)), 'arch_repo' => arch_repo.to_s,
            'pkgnames' => (pkgnames || name).split(','), 'deps' => (deps == '-' ? [] : deps.to_s.split(',')) }
        end
      else
        []
      end
    end
  end

  # The dependency graph over the candidates, for the claim order: each
  # package's weight is how many packages need it directly, so what
  # unblocks the most builds goes first. Direct, not transitive: through
  # makedepends and checkdepends the graph is one big tangle of cycles, and
  # a transitive count puts a third of the packages at "everything".
  # Dependencies are matched by the names the packages provide as pkgname
  # (the index records depends, makedepends and checkdepends); a dependency
  # on a name only `provides` gives is not seen.
  #   -> { pkgbase => weight }
  def self.dependents
    return @dependents[1] if @dependents && @dependents[0].equal?(packages)

    cands = candidates
    by_pkgname = cands.flat_map { |p| p['pkgnames'].map { |n| [n, p['pkgbase']] } }.to_h
    weights = cands.to_h { |p| [p['pkgbase'], 0] }
    cands.each do |p|
      p['deps'].filter_map { |d| by_pkgname[d] }.uniq.each { |b| weights[b] += 1 unless b == p['pkgbase'] }
    end
    @dependents = [packages, weights]
    weights
  end

  # Packages whose PKGBUILD version is not the one we last built, in claim
  # order: the farm's own packages (ARCHCI_PKG_ALSO, i.e. archci) first, then
  # packages whose dependencies from this repository are all built, at their
  # current version, before those still waiting for one (so a library goes
  # before what links it, and a build is not tried before it can succeed:
  # an update waiting for a library's update comes after the whole backlog);
  # within those, updates of packages we already publish before the
  # never-built backlog; then by the dependency graph, the package needed by
  # the most others first (dependents, direct); then by
  # origin: Arch's core, then extra, then multilib, then the repository's
  # local packages, then those from the AUR; an arch's own packages before
  # the any packages; alphabetically last.
  # An entry whose waited-for dependency has a job running or queued (a
  # retry pending too) is 'expected': claim (archci-next) passes it over,
  # since the build would only fail before the dependency lands; one whose
  # dependency is merely unbuilt is claimed once nothing better is left,
  # so a dependency cycle still gets its builds tried.
  # Nothing is stored; this is computed from the package index, built/ and the
  # queue on every call.
  #   arch:   only jobs a worker of this arch may build (its own, plus "any" if
  #           it is ARCHCI_ANY_ARCH); nil for every enabled arch
  #   limit:  return only this many candidates
  #   queued: include packages with a job running or queued (for waiting_for)
  def self.outstanding(arch: nil, limit: nil, queued: false)
    cfg = config
    repo = cfg['ARCHCI_REPO']
    running = jobs('running').to_h { |j| [[j['repo'], j['pkgbase'], j['arch']], true] }
    queued_commits = Hash.new { |h, k| h[k] = [] } # pending or failed, by commit
    given_up = {}                          # failed for good at this commit: not coming
    %w[pending failed].each do |q|
      jobs(q).each do |j|
        queued_commits[[j['repo'], j['pkgbase'], j['arch']]] << j['commit']
        given_up[[j['pkgbase'], j['arch']]] = j['commit'] if j['final'] == '1'
      end
    end

    also = cfg['ARCHCI_PKG_ALSO'].to_s.split   # built whatever their source
    ignorearch = cfg['ARCHCI_IGNOREARCH'] != '0'
    # a build waits for its source package when builds must never fetch
    # upstream (ARCHCI_SOURCES_REQUIRED): claimed once it is released
    sources_required = cfg['ARCHCI_SOURCES_REQUIRED'] != '0'
    candidates = self.candidates

    # An arch-independent package is one job, for workers of the any arch,
    # and is pooled for every arch; those come after the arch's own packages.
    # Anything else is offered to every enabled arch that its arch array
    # lists, and Arch's own packages (source arch, which list x86_64 only by
    # convention) to a port arch too, built with --ignorearch
    # (ARCHCI_IGNOREARCH; archci-build passes it on a port arch); an AUR or
    # local package lists the arches it has binaries or a port for.
    per_arch, any_pkgs = candidates.partition { |p| p['arches'] != ['any'] }
    # which pkgbase of this repository provides each name a dependency may use
    by_pkgname = candidates.flat_map { |p| p['pkgnames'].map { |n| [n, p['pkgbase']] } }.to_h
    # a dependency is met once its pkgbase is built at its current version
    # for the arch, or as an any package (built at an older one, its update
    # is waited for: the dependent's new version usually needs it), and the
    # signer has released it (released?: one of its packages at that version
    # in the dependent's arch's released database, every arch's holds the
    # any packages; the chroot installs from the release); one that gave up
    # at its current commit is not waited for (the chroot falls back on the
    # mirrors' copy, if any). The built names come from one listing per
    # arch, the versions from the built records (cached): the check runs
    # for every dependency of every package on every archci top frame.
    by_base = candidates.to_h { |p| [p['pkgbase'], p] }
    weight = dependents
    built_names = Hash.new do |h, a|
      dir = File.join(home, 'built', "#{repo}-#{a}")
      h[a] = File.directory?(dir) ? Dir.children(dir).to_set : Set.new
    end
    # (dep_base built as built_arch, released in db_arch's database)
    current = Hash.new do |h, (dep_base, built_arch, db_arch)|
      path = File.join(home, 'built', "#{repo}-#{built_arch}", dep_base)
      version = by_base[dep_base]['version']
      h[[dep_base, built_arch, db_arch]] = built_names[built_arch].include?(dep_base) && built_record(path)&.first == version &&
                                           by_base[dep_base]['pkgnames'].any? { |n| released?(repo, db_arch, "#{n} #{version}", path) }
    end
    dep_built = lambda do |dep_base, a|
      current[[dep_base, a, a]] || current[[dep_base, 'any', a]] ||
        [a, 'any'].any? { |x| given_up[[dep_base, x]] == by_base[dep_base]['commit'] }
    end
    updates = []
    backlog = []
    (arch ? [arch] : arches).each do |a|
      list = a == any_arch ? per_arch + any_pkgs : per_arch
      list.each do |p|
        any = p['arches'] == ['any']
        job_arch = any ? 'any' : a
        next if !any && !p['arches'].include?(a) && (a == 'x86_64' || !ignorearch || p['source'] != 'arch')
        next if p['profile'] == 'multilib' && a != 'x86_64'   # 32-bit x86 libraries: x86_64 only, whatever --ignorearch says

        # built record: "version commit" and, for an any package, the arches it
        # was pooled for; an arch enabled since makes the package outstanding again
        built, _commit, pooled = built_record(File.join(home, 'built', "#{repo}-#{job_arch}", p['pkgbase'])) || []
        next if built == p['version'] && (!any || (arches - pooled.to_s.split(',')).empty?)
        unless queued
          next if running[[repo, p['pkgbase'], job_arch]]                      # one build per package and arch at a time
          next if queued_commits[[repo, p['pkgbase'], job_arch]].include?(p['commit']) # queued, in retry backoff, or given up
        end

        # the dependencies this repository itself provides, not built yet for
        # this arch (an any package's on the any arch): built after them
        waiting = p['deps'].filter_map { |d| by_pkgname[d] }.uniq
                           .reject { |b| b == p['pkgbase'] || dep_built[b, any ? any_arch : a] }
        expected = waiting.any? do |b|
          dep_arch = by_base[b]['arches'] == ['any'] ? 'any' : (any ? any_arch : a)
          running[[repo, b, dep_arch]] || queued_commits[[repo, b, dep_arch]].include?(by_base[b]['commit'])
        end
        expected ||= sources_required && source_file(repo, p).nil?
        entry = { 'repo' => repo, 'arch' => job_arch, 'pkgbase' => p['pkgbase'], 'version' => p['version'],
                  'commit' => p['commit'], 'profile' => p['profile'], 'prio' => built ? 1 : 5, 'waiting' => waiting, 'expected' => expected,
                  'network' => p['network'], 'dependents' => weight[p['pkgbase']],
                  'rank' => [also.include?(p['pkgbase']) ? 0 : 1, waiting.empty? ? 0 : 1, built ? 0 : 1, -weight[p['pkgbase']],
                             origin_rank(p), any ? 1 : 0, p['pkgbase']] }
        (built ? updates : backlog) << entry
      end
    end
    ordered = (updates + backlog).sort_by { |e| e['rank'] }
    limit ? ordered.first(limit) : ordered
  end

  # The packages the farm builds: the index less skip_build and, with
  # ARCHCI_PKG_SOURCES or ARCHCI_PKG_REPOS, those of another source or Arch
  # repository (ARCHCI_PKG_ALSO excepted). archci_pkg_wanted in
  # archci-common.sh is the same rule for the claim.
  def self.candidates
    sources = config['ARCHCI_PKG_SOURCES'].to_s.split
    repos = config['ARCHCI_PKG_REPOS'].to_s.split
    also = config['ARCHCI_PKG_ALSO'].to_s.split
    packages.reject do |p|
      next false if also.include?(p['pkgbase'])

      p['skip'] || (!sources.empty? && !sources.include?(p['source'])) || (!repos.empty? && !repos.include?(origin(p)))
    end
  end

  # The packages without a source package for their current commit, in claim
  # order, as src jobs for the sourcer: like outstanding, less the waiting
  # (sources have no dependencies): the farm's own packages first, then
  # those the sourcer has fetched before (their update) before the never
  # fetched, then the package needed by the most others (its sources unblock
  # the most builds), then by origin and name. One src job per package at a
  # time; a queued or failed one at the current commit is not offered again.
  #   queued: include packages with a src job running or queued (for the counts)
  def self.outstanding_sources(queued: false)
    repo = config['ARCHCI_REPO']
    also = config['ARCHCI_PKG_ALSO'].to_s.split
    busy = {}
    unless queued
      jobs('running').each { |j| busy[[j['pkgbase'], j['commit']]] = true if j['arch'] == 'src' }
      %w[pending failed].each { |q| jobs(q).each { |j| busy[[j['pkgbase'], j['commit']]] = true if j['arch'] == 'src' } }
    end
    weight = dependents
    candidates.filter_map do |p|
      _version, commit, = built_record(File.join(home, 'built', "#{repo}-src", p['pkgbase'])) || []
      next if commit == p['commit'] || busy[[p['pkgbase'], p['commit']]]

      { 'repo' => repo, 'arch' => 'src', 'pkgbase' => p['pkgbase'], 'version' => p['version'], 'commit' => p['commit'],
        'profile' => p['profile'], 'prio' => commit ? 1 : 5, 'waiting' => [], 'expected' => false, 'dependents' => weight[p['pkgbase']],
        'rank' => [also.include?(p['pkgbase']) ? 0 : 1, commit ? 0 : 1, -weight[p['pkgbase']], origin_rank(p), p['arches'] == ['any'] ? 1 : 0, p['pkgbase']] }
    end.sort_by { |e| e['rank'] }
  end

  # The dependencies from this repository a job for pkgbase on job_arch
  # ("any" for an any package) still waits for (see outstanding); [] when
  # none, or when the package is not outstanding at all. A src job waits
  # for nothing.
  def self.waiting_for(pkgbase, job_arch)
    return [] if job_arch == 'src'

    a = job_arch == 'any' ? any_arch : job_arch
    outstanding(arch: a, queued: true).find { |e| e['pkgbase'] == pkgbase && e['arch'] == job_arch }&.dig('waiting') || []
  end

  # Everything archci-top draws, computed once from the queue, the built
  # records and the package index.
  def self.snapshot(now = Time.now)
    repo = config['ARCHCI_REPO']
    counts = QUEUES.to_h { |q| [q, Dir.glob(File.join(queue(q), '*.job')).size] }
    # built and tracked are keyed like the built/ directories: "<repo>-<arch>"
    # per enabled arch, plus "<repo>-any" for the arch-independent packages.
    pkgs = packages.reject { |p| p['skip'] }
    any_count = pkgs.count { |p| p['arches'] == ['any'] }
    sets = arches.map { |a| ["#{repo}-#{a}", pkgs.size - any_count] } << ["#{repo}-any", any_count]
    sets << ["#{repo}-src", candidates.size]
    outstanding = self.outstanding
    # the sourcer: packages with a source package for their current commit
    # (the src built records), those still to fetch (src jobs to come, queued
    # or running), fetches that failed, and when one last came in
    src_dir = File.join(home, 'built', "#{repo}-src")
    sources = {
      'ready' => candidates.count { |p| built_record(File.join(src_dir, p['pkgbase']))&.at(1) == p['commit'] },
      'needed' => outstanding_sources(queued: true).size,
      'failed' => jobs('failed').count { |j| j['arch'] == 'src' },
      'last' => Dir.glob(File.join(src_dir, '*')).map { |f| File.mtime(f) }.max&.utc&.iso8601
    }
    updates = outstanding.count { |e| e['prio'] == 1 }
    by_name = packages.to_h { |p| [p['pkgbase'], p] }
    job = lambda do |j|
      { 'pkgbase' => j['pkgbase'], 'version' => j['version'], 'repo' => j['repo'], 'arch' => j['arch'],
        'worker' => j['worker'], 'attempt' => j['attempt'], 'origin' => origin(by_name[j['pkgbase']]) }
    end
    running = jobs('running').sort_by { |j| j['claimed'].to_s }.map do |j|
      job[j].merge('claimed' => j['claimed'], 'heartbeat_age_s' => (now - j['mtime']).to_i, **j.slice(*HOST_STATS, *JOB_STATS))
    end
    failed = jobs('failed').sort_by { |j| -j['mtime'].to_i }.map do |j|
      job[j].merge('id' => j['id'], 'final' => j['final'] == '1', 'finished' => j['finished'],
                   'log' => File.join(home, 'logs', j['repo'], j['pkgbase'], j['version'], j['arch'], "attempt-#{j['attempt']}.log"))
    end
    # What archci-signer-status last saw of the signer through R2, if it runs.
    status = File.join(home, 'signer.status')
    signer = begin
      JSON.parse(File.read(status)).merge('age_s' => (now - File.mtime(status)).to_i)
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end
    done_paths = Dir.glob(File.join(queue('done'), '*.job'))
    done = jobs('done', newest: 50).sort_by { |j| -j['mtime'].to_i }
    recent = done.map do |j|
      job[j].merge('finished' => j['finished'], 'heartbeat' => j['heartbeat'], **j.slice(*HOST_STATS))
    end
    {
      'repo' => repo,
      'arches' => arches,
      'queue' => counts,
      'done_last_hour' => done_paths.count { |p| now - File.mtime(p) < 3600 },
      'outstanding' => { 'updates' => updates, 'backlog' => outstanding.size - updates },
      'sources' => sources,
      'tracked' => sets.to_h,
      'built' => sets.to_h { |key, _| [key, Dir.glob(File.join(home, 'built', key, '*')).size] },
      'hosts' => hosts(running, recent, Dir.glob(File.join(home, 'hosts', '*')).filter_map { |p| read_job(p) }, now),
      'signer' => signer,
      'running' => running,
      'failed' => failed
    }
  end

  # ---- every job, its log and its story: what archci jobs and archci web show ----
  ERROR_RE = /error:|ERROR|FAILED|Unmet dependencies|target not found|Failure while downloading|did not pass the validity|returned error: 4\d\d/
  NOT_ERROR_RE = /gpg:|Verifying|Build failed, check|makechrootpkg exited|the build exited|archci-build finished|-Werror|ERRORFUNC|_error|error_/
  def self.error_line?(line) = line.match?(ERROR_RE) && !line.match?(NOT_ERROR_RE)

  # the attempt's archived log (written when the job finishes)
  def self.log_path(j)
    File.join(home, 'logs', j['repo'] || config['ARCHCI_REPO'], j['pkgbase'], j['version'], j['arch'], "attempt-#{j['attempt']}.log")
  end

  # one job by id, read from whichever queue holds it (no scan of the rest);
  # nil if no queue has it. Same shape as an all_jobs entry.
  def self.find_job(id)
    QUEUES.each do |q|
      path = File.join(queue(q), "#{id}.job")
      next unless File.exist?(path)

      j = read_job(path) or next
      pkg = packages.find { |p| p['pkgbase'] == j['pkgbase'] }
      return j.merge('state' => q, 'origin' => origin(pkg) || '-', 'log' => log_path(j))
    end
    nil
  end

  # the id of the src job that produced a build's source package: same pkgbase
  # and version, arch src (one repo per master). Prefer the one that succeeded
  # (done), then running, failed, pending; newest first. nil if pruned.
  # (The id is <prio>-<ts>-<repo>,<pkgbase>,<version>,<arch>, so the glob
  # matches on the ",<pkgbase>,<version>,src" suffix.)
  def self.find_src_job(_repo, pkgbase, version)
    %w[done running failed pending].each do |q|
      paths = Dir.glob(File.join(queue(q), "*,#{pkgbase},#{version},src.job"))
      best = paths.max_by { |p| File.mtime(p) } or next
      return File.basename(best, '.job')
    end
    nil
  end

  # every job the master holds, each with its queue as 'state', its package's
  # origin and its log path
  def self.all_jobs
    by_name = packages.to_h { |p| [p['pkgbase'], p] }
    QUEUES.flat_map do |q|
      jobs(q).map { |j| j.merge('state' => q, 'origin' => origin(by_name[j['pkgbase']]) || '-', 'log' => log_path(j)) }
    end
  end

  # the journal's matches for a running job: a build's unit, or the sourcer's
  # service on its host for a src job (what archci-top keys on)
  def self.journal_matches(j)
    if j['arch'] == 'src'
      ['_SYSTEMD_UNIT=archci-sourcer.service', "_HOSTNAME=#{j['worker']}", 'SYSLOG_IDENTIFIER=archci-sourcer']
    else
      name = "#{j['repo']}-#{j['pkgbase']}-#{j['version']}-#{j['arch']}-a#{j['attempt']}".gsub(/[^A-Za-z0-9:_.-]/, '_')
      ["_SYSTEMD_UNIT=archci-build@#{name}.service"]
    end
  end

  # the job's log lines and the index of its first error: the archived log for
  # a finished job, the journal's last lines for a running one
  def self.read_log(j, lines: 400)
    journal = config['ARCHCI_REMOTE_JOURNAL']
    text = if j['state'] == 'running' && journal && File.directory?(journal)
             out, = Open3.capture2('journalctl', '-D', journal, '--no-pager', '-a', '-o', 'cat', '-n', lines.to_s, *journal_matches(j), err: File::NULL)
             out.scrub.lines(chomp: true)
           else
             File.exist?(j['log']) ? File.read(j['log']).scrub.lines(chomp: true) : []
           end
    [text, j['state'] == 'done' ? nil : text.index { |l| error_line?(l) }]   # a done job's line of interest is its last
  end

  # the job's story in one line: state, where, when, what it had
  def self.story(j)
    max = config['ARCHCI_MAX_ATTEMPTS'].to_i
    s = case j['state']
        when 'pending' then "pending since #{j['created']}, attempt #{j['attempt'] + 1} of #{max} next"
        when 'running' then "running on #{j['worker']} since #{j['claimed']}, attempt #{j['attempt']} of #{max}#{j['phase'] ? ", in #{j['phase']}" : ''}"
        when 'done' then "done #{j['finished']} on #{j['worker']}, attempt #{j['attempt']}"
        when 'failed' then "failed #{j['finished']} on #{j['worker']}, attempt #{j['attempt']} of #{max}#{j['final'] ? ': gave up' : ''}"
        end
    had = []
    had << "sources #{j['sources']}" if j['sources']
    had << "network #{j['network']}" if j['network']
    had << "#{j['rss']}M rss, #{j['peak']}M peak" if j['rss']
    had.empty? ? s : "#{s}; #{had.join(', ')}"
  end

  # Claim order among packages of one class: Arch's core before extra before
  # multilib, then this repository's own (local) packages, then AUR ones.
  ORIGIN_RANK = { %w[arch core] => 0, %w[arch extra] => 1, %w[arch multilib] => 2 }.freeze
  # Where a package comes from, as archci top shows it: Arch's repository
  # (core, extra, multilib; "arch" when package.json does not say), aur or
  # local; nil for a package the index no longer has.
  def self.origin(pkg)
    return nil unless pkg

    if pkg['source'] == 'arch'
      %w[- ''].include?(pkg['arch_repo'].to_s) ? 'arch' : pkg['arch_repo']
    else
      pkg['source']
    end
  end

  def self.origin_rank(pkg)
    ORIGIN_RANK.fetch([pkg['source'], pkg['arch_repo']]) do
      case pkg['source']
      when 'arch' then 3
      when 'local' then 4
      when 'aur' then 5
      else 6
      end
    end
  end

  def self.log(msg)
    warn "#{File.basename($PROGRAM_NAME)}: #{msg}"
    return if ENV['JOURNAL_STREAM']

    system('logger', '-t', File.basename($PROGRAM_NAME), '--', msg, exception: false)
  end
end
