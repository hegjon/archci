# frozen_string_literal: true

# archci.rb -- shared helpers for the ruby parts of archci (scan, top).
# Mirrors archci-common.sh: same config file, same job file format.
require 'etc'
require 'fileutils'
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
    'ARCHCI_REMOTE_JOURNAL' => '/var/lib/archci/journal',
    'ARCHCI_LOG_MAX_LINES' => '20000'
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

  # What is released, as archci-publish last listed it (released/<repo>-
  # <arch>: "name version" per package the arch's database names;
  # released/<repo>-src: the signed source packages): a Set of the lines,
  # nil without a listing (nothing indexed yet), cached by the file's mtime.
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

  # The signing pipeline as the master sees it: what waits in the pool
  # for the signer (files without a release signature, an any package once,
  # the rejected ones apart, and the oldest's age) and what is released per
  # arch (the listing archci-publish writes from each database: its entry
  # count and when it last changed; nil before the first index).
  def self.signer_status(now)
    repo = config['ARCHCI_REPO']
    pool = File.join(home, 'repo')
    files = Dir.glob(File.join(pool, '*', 'os', '*', '*.{pkg.tar.zst,src.tar.zst,src.tar.gz}'))
    waiting = files.reject { |f| File.exist?("#{f}.sig") || File.exist?("#{f}.rejected") }
    names = waiting.map { |f| File.basename(f) }.uniq
    oldest = waiting.map { |f| File.mtime(f) }.min
    rejected = Dir.glob(File.join(pool, '*', 'os', '*', '*.rejected')).size
    release = arches.to_h do |a|
      listing = File.join(home, 'released', "#{repo}-#{a}")
      if File.exist?(listing)
        [a, { 'updated' => File.mtime(listing).utc.iso8601, 'packages' => File.readlines(listing).size }]
      else
        [a, { 'updated' => nil, 'packages' => nil }]
      end
    end
    { 'unsigned' => { 'waiting' => names.size, 'oldest_s' => oldest && (now - oldest).to_i }, 'rejected' => rejected, 'release' => release }
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
  # POLLS (hosts/<worker>), from the newest stats any of its workers sent; a
  # host whose last poll is older than POLL_TTL is dropped. Its arch is what a
  # worker without one in its name builds; the sourcer is a worker of arch src.
  # Order: the master, the sourcers, then the workers by name.
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

  # The dependency graph over the candidates: each package's weight is how many
  # need it directly (direct, not transitive -- makedepends/checkdepends make a
  # transitive count one big cycle). Dependencies match the names packages
  # provide as pkgname; one on a `provides`-only name is not seen.
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

  # Packages whose PKGBUILD version is not the one last built, in claim order:
  # ALSO first; deps-built before still-waiting; updates before never-built; then
  # by dependency graph, origin (core/extra/multilib/local/aur), own-arch, name.
  # A package waiting on a running/queued dep is 'expected' and passed over; one
  # on an unbuilt dep is claimed last, so cycles build. arch: jobs this worker may
  # build (nil=all); limit: cap; queued: count running/queued too (waiting_for).
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

    # An "any" package is one job for the any arch, pooled to every arch, after
    # the arch's own. Everything else goes to each enabled arch its array
    # lists, and Arch's x86_64-only packages to port arches too with
    # --ignorearch (ARCHCI_IGNOREARCH); AUR/local packages only where listed.
    per_arch, any_pkgs = candidates.partition { |p| p['arches'] != ['any'] }
    # which pkgbase of this repository provides each name a dependency may use
    by_pkgname = candidates.flat_map { |p| p['pkgnames'].map { |n| [n, p['pkgbase']] } }.to_h
    # a dependency is met once its pkgbase is built at its current version for
    # the arch (or as an any package) and the signer has released it
    # (released?: in the arch's released database, from which the chroot
    # installs); one that gave up at its commit is not waited for. Built names
    # come from one listing per arch, versions from the cached built records.
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
    packages.reject { |p| p['skip'] || !wanted?(p) }
  end

  # The filter alone (ARCHCI_PKG_SOURCES, ARCHCI_PKG_REPOS, ARCHCI_PKG_ALSO),
  # as archci_pkg_wanted applies it to a queued job: skip_build does not
  # count, a job for a skipped package is the operator's doing. nil (a
  # package the index no longer has) is not wanted.
  def self.wanted?(pkg)
    return false unless pkg

    sources = config['ARCHCI_PKG_SOURCES'].to_s.split
    repos = config['ARCHCI_PKG_REPOS'].to_s.split
    return true if config['ARCHCI_PKG_ALSO'].to_s.split.include?(pkg['pkgbase'])

    (sources.empty? || sources.include?(pkg['source'])) && (repos.empty? || repos.include?(origin(pkg)))
  end

  # Why the claim passes a pending job over, for every worker: the package
  # is outside the filter (a retry of one excluded since, or enqueued by
  # hand regardless), or, with ARCHCI_SOURCES_REQUIRED, its source package
  # is not released yet. nil for a job the next claim of its arch may take.
  def self.held_reason(j, pkg)
    return 'outside the farm\'s filter' unless wanted?(pkg)
    return nil if j['arch'] == 'src' || config['ARCHCI_SOURCES_REQUIRED'] == '0'

    source_file(j['repo'], 'pkgbase' => j['pkgbase'], 'commit' => j['commit']) ? nil : 'waiting for its source package'
  end

  # Packages without a source package for their current commit, in claim order,
  # as src jobs: like outstanding but without the waiting (sources have no
  # deps) -- ALSO first, then re-fetches before never-fetched, then by graph,
  # origin, name. One src job per package; a queued or failed one at the commit
  # is not re-offered.  queued: include running/queued src jobs (for the counts).
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
    by_name = packages.to_h { |p| [p['pkgbase'], p] }
    # pending jobs no claim takes as things stand (held_reason): they wait
    # in pending/ but are not work for the workers
    counts['held'] = jobs('pending').count { |j| held_reason(j, by_name[j['pkgbase']]) }
    # built and tracked are keyed like the built/ directories: "<repo>-<arch>"
    # per enabled arch, plus "<repo>-any" for the arch-independent packages
    # and "<repo>-src" for the source packages; both count the packages the
    # farm builds now (candidates), so a filter narrows them together and
    # what was built before the filter does not count past the total
    pkgs = candidates
    any_count = pkgs.count { |p| p['arches'] == ['any'] }
    sets = arches.map { |a| ["#{repo}-#{a}", pkgs.size - any_count] } << ["#{repo}-any", any_count]
    sets << ["#{repo}-src", pkgs.size]
    names = pkgs.map { |p| p['pkgbase'] }.to_set
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
    job = lambda do |j|
      { 'pkgbase' => j['pkgbase'], 'version' => j['version'], 'repo' => j['repo'], 'arch' => j['arch'],
        'worker' => j['worker'], 'attempt' => j['attempt'], 'origin' => origin(by_name[j['pkgbase']]) }
    end
    running = jobs('running').sort_by { |j| j['claimed'].to_s }.map do |j|
      job[j].merge('claimed' => j['claimed'], 'heartbeat_age_s' => (now - j['mtime']).to_i, **j.slice(*HOST_STATS, *JOB_STATS))
    end
    failed = jobs('failed').sort_by { |j| -j['mtime'].to_i }.map do |j|
      j = j.merge('state' => 'failed')
      job[j].merge('id' => j['id'], 'final' => j['final'] == '1', 'finished' => j['finished'], 'log' => log_where(j),
                   **j.slice('state', 'claimed', 'created', 'error', 'last'))
    end
    signer = signer_status(now)
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
      'built' => sets.to_h { |key, _| [key, Dir.glob(File.join(home, 'built', key, '*')).count { |f| names.include?(File.basename(f)) }] },
      'hosts' => hosts(running, recent, Dir.glob(File.join(home, 'hosts', '*')).filter_map { |p| read_job(p) }, now),
      'signer' => signer,
      'running' => running,
      'failed' => failed
    }
  end

  # ---- every job, its log and its story: what archci jobs and archci web show ----
  ERROR_RE = /error:|ERROR|FAILED|Unmet dependencies|target not found|Failure while downloading|did not pass the validity|returned error: 4\d\d|==> build killed|terminated by signal/
  # (a test suite's summary counts, "# ERROR: 0" and "# FAIL: 0", are not errors either)
  NOT_ERROR_RE = /gpg:|Verifying|Build failed, check|makechrootpkg exited|the build exited|archci-build finished|-Werror|ERRORFUNC|_error|error_|\A# (ERROR|FAIL|XFAIL|XPASS|PASS|SKIP|TOTAL):\s*\d+\s*\z/
  def self.error_line?(line) = line.match?(ERROR_RE) && !line.match?(NOT_ERROR_RE)

  # where a job's log is, for a human: the journalctl the master runs to
  # read it as entries (journal_cmd, what the web's log window is built
  # from; -o cat in place of -o json gives the lines); nil for a pending
  # job, which has none yet
  def self.log_where(j)
    journal_cmd(j, output: 'json')&.join(' ')
  end

  # one job by id, read from whichever queue holds it (no scan of the rest);
  # nil if no queue has it. Same shape as an all_jobs entry.
  def self.find_job(id)
    QUEUES.each do |q|
      path = File.join(queue(q), "#{id}.job")
      next unless File.exist?(path)

      j = read_job(path) or next
      pkg = packages.find { |p| p['pkgbase'] == j['pkgbase'] }
      return j.merge('state' => q, 'origin' => origin(pkg) || '-').then { |x| x.merge('log' => log_where(x)) }
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
      jobs(q).map { |j| j.merge('state' => q, 'origin' => origin(by_name[j['pkgbase']]) || '-').then { |x| x.merge('log' => log_where(x)) } }
    end
  end

  # ---- a job's log: the workers' journals on the master, nothing else ----
  # The workers stream their archci journal namespace to the master
  # (systemd-journal-remote, ARCHCI_REMOTE_JOURNAL; see docs/monitoring.md);
  # a build's output is its unit's entries there, a fetch's the sourcer
  # service's on its host. That journal is the log store: nothing is copied
  # to files, and a log lives as long as the journal keeps it.

  # the journal's matches for a job: a build's unit on its worker's host (a
  # retry is another unit, -aN; a requeued attempt reuses the unit, so the
  # window below tells the runs apart), or the sourcer's service on its host
  # for a src job (what archci-top keys on as well)
  def self.journal_matches(j)
    if j['arch'] == 'src'
      ['_SYSTEMD_UNIT=archci-sourcer.service', "_HOSTNAME=#{j['worker']}", 'SYSLOG_IDENTIFIER=archci-sourcer']
    else
      name = "#{j['repo']}-#{j['pkgbase']}-#{j['version']}-#{j['arch']}-a#{j['attempt']}".gsub(/[^A-Za-z0-9:_.-]/, '_')
      ["_SYSTEMD_UNIT=archci-build@#{name}.service", *("_HOSTNAME=#{worker_host(j['worker']).first}" if j['worker'])]
    end
  end

  # the time window a job's entries fall in, [since, until] as epoch seconds
  # (until nil while it runs): from its claim (a finished job keeps
  # 'claimed'; 'created' for one from before it did) to its report, each
  # widened by JOURNAL_SLACK for the worker's clock against the master's and
  # a report that lands after the last line. journalctl also skips the
  # journal files outside the window, which is what makes a read quick.
  JOURNAL_SLACK = 120
  def self.journal_window(j)
    from = j['claimed'] || j['created']
    since = from ? Time.iso8601(from).to_i - JOURNAL_SLACK : 0
    till = j['finished'] && (Time.iso8601(j['finished']).to_i + JOURNAL_SLACK)
    [since, till]
  rescue ArgumentError
    [0, nil]
  end

  # the job's log, as [lines, error_at, cursor]: its entries in the
  # workers' journal (none for a pending job, or without the journal) --
  # the whole log, or, for a running job, only what follows a cursor
  # (after:) so a poll fetches just what it has not seen. error_at is the
  # first error's index within these lines (nil for a done job, whose point
  # of interest is its last line); cursor resumes the next poll of a running
  # job (journald prints it as a trailing "-- cursor: " line), nil once it
  # has finished.
  def self.read_log(j, after: nil)
    cmd = journal_cmd(j, after: after, output: 'cat') or return [[], nil, nil]
    out, = Open3.capture2(*cmd, err: File::NULL)
    lines = out.scrub.lines(chomp: true)
    cursor = lines.pop&.delete_prefix('-- cursor: ') if lines.last&.start_with?('-- cursor: ')
    cursor ||= after if j['state'] == 'running'   # nothing new: journalctl prints no cursor, the poll keeps its own
    lines = own_lines(lines, j['id']) unless after && !after.empty?
    [lines, j['state'] == 'done' ? nil : lines.index { |l| error_line?(l) }, cursor]
  end

  # the job's own lines among what its matches and window hold: the window's
  # slack lets in the sourcer's previous or next fetch on the same host, or
  # an earlier run of a requeued attempt's unit. archci-build and
  # archci-sourcer open a log with a header naming the job ("==> archci-build
  # <version>" then "    job <id>", or the id on the line), so the log starts
  # at the last such header that names this job and ends before the next
  # header, another job's. Without a header naming the job (a log from
  # before they did) nothing is cut. text: the line of an element, for
  # entries.
  LOG_HEADER = ['==> archci-build ', '==> archci-sourcer '].freeze
  def self.own_lines(lines, id, text: ->(l) { l })
    headers = lines.each_index.select { |i| text[lines[i]].start_with?(*LOG_HEADER) && !text[lines[i]].start_with?(*BUILD_END) }
    start = headers.reverse.find { |i| lines[i, 4].any? { |l| text[l].include?(id) } } or return lines
    stop = headers.find { |i| i > start } || lines.size
    lines[start...stop]
  end

  # the journalctl that reads a job's log (read_log, read_entries): the
  # job's matches within its window or, resuming a running job, after the
  # cursor (journalctl takes one or the other), as OUTPUT: 'cat' for the
  # lines (with the cursor to resume from while the job runs), 'json' for
  # the entries. nil for a pending job, or without the journal.
  def self.journal_cmd(j, after: nil, output: 'cat')
    journal = config['ARCHCI_REMOTE_JOURNAL']
    return nil unless %w[running done failed].include?(j['state']) && journal && File.directory?(journal)

    since, till = journal_window(j)
    cmd = ['journalctl', '-D', journal, '--no-pager', '-a', '-q', '-o', output]
    # a cursor resumes whatever the state: a poll that watched the job run
    # asks once more after it finished, and gets the rest, not the log again
    resume = after && !after.empty?
    cmd += resume ? ['--after-cursor', after] : ["--since=@#{since}"]
    cmd << "--until=@#{till}" if till
    cmd << '--show-cursor' if output == 'cat' && j['state'] == 'running'
    # plus the cursor and the __ timestamps, always printed; the ARCHCI_ fields
    # are on archci's own records (archci_record), the invocation id on every
    # line of a unit's run
    cmd << "--output-fields=MESSAGE,PRIORITY,_PID,_SOURCE_REALTIME_TIMESTAMP,_SYSTEMD_INVOCATION_ID,#{RECORD_FIELDS.join(',')}" if output == 'json'
    cmd + journal_matches(j)
  end

  # the job's log as journal entries, [entries, error_at, cursor], for a
  # browser to build the log window from without reading the log itself:
  # each entry as journalctl -o json names its fields, '__CURSOR' (the
  # entry's own, to resume or link from), its timestamps
  # ('__REALTIME_TIMESTAMP', when journald took the line, microseconds
  # since the epoch as a string; '__MONOTONIC_TIMESTAMP'; and
  # '_SOURCE_REALTIME_TIMESTAMP' when the sender stamped it), 'MESSAGE'
  # (the line) and 'PRIORITY' (syslog's, as a string: a unit's
  # stdout logs at 6, its stderr at 3), plus 'phase' => 'online' |
  # 'offline' | 'loopback' on a slice marker line (log_phase), absent
  # otherwise. error_at and cursor as read_log; the cursor is the last
  # entry's.
  RECORD_FIELDS = %w[ARCHCI_JOB ARCHCI_ATTEMPT ARCHCI_EVENT ARCHCI_RC ARCHCI_SLICE ARCHCI_NETWORK ARCHCI_PACKAGE ARCHCI_PACKAGES ARCHCI_VERSION ARCHCI_COMMIT ARCHCI_PROFILE ARCHCI_HOST].freeze
  # At most ARCHCI_LOG_MAX_LINES entries are kept: the first three quarters
  # of that and the last quarter, with one marker entry (no cursor,
  # priority 4) in place of what is between. journalctl's output is read
  # as it comes, never whole: a test suite that dumps its files can write
  # hundreds of thousands of lines, and reading them all into memory killed
  # the master's export (its OOM, 2026-09-16).
  def self.read_entries(j, after: nil)
    cmd = journal_cmd(j, after: after, output: 'json') or return [[], nil, nil]
    limit = [config['ARCHCI_LOG_MAX_LINES'].to_i, 8].max
    tail_n = limit / 4
    head_n = limit - tail_n
    head = []
    tail = []       # the last tail_n entries once the head is full
    dropped = 0
    first_dropped = nil
    cursor = nil
    Open3.popen2(*cmd, err: File::NULL) do |stdin, stdout, _thread|
      stdin.close
      stdout.each_line do |line|
        e = begin
          JSON.parse(line.scrub)
        rescue JSON::ParserError
          next
        end
        m = e['MESSAGE']
        m = m.pack('C*').scrub if m.is_a?(Array)   # not UTF-8: journalctl gives the bytes
        next unless m.is_a?(String)

        entry = e.slice('__CURSOR', '__REALTIME_TIMESTAMP', '__MONOTONIC_TIMESTAMP', '_SOURCE_REALTIME_TIMESTAMP', 'PRIORITY', '_PID', '_SYSTEMD_INVOCATION_ID', *RECORD_FIELDS).merge('MESSAGE' => m)
        phase = log_phase(m)
        entry['phase'] = phase if phase
        if head.size < head_n
          head << entry
        else
          tail << entry
          if tail.size > tail_n
            first_dropped ||= tail.first
            tail.shift
            dropped += 1
          end
        end
        cursor = e['__CURSOR']
      end
    end
    entries = head
    if dropped.positive?
      entries << { '__REALTIME_TIMESTAMP' => first_dropped['__REALTIME_TIMESTAMP'], 'PRIORITY' => '4',
                   'MESSAGE' => "... #{dropped} line(s) not shown: the log has more than #{limit} lines (ARCHCI_LOG_MAX_LINES); the first #{head_n} and the last #{tail_n} are" }
    end
    entries.concat(tail)
    cursor = j['state'] == 'running' ? (cursor || after) : nil
    entries = own_lines(entries, j['id'], text: ->(e) { e['MESSAGE'] }) unless after && !after.empty?
    [entries, j['state'] == 'done' ? nil : entries.index { |e| error_line?(e['MESSAGE']) }, cursor]
  end

  # a build's marker lines and the phase each opens: archci-build's slice
  # transitions ('online': the dependencies install with the network;
  # 'offline' or 'loopback' or 'online' again: the build itself, by the
  # package's network flag), and makepkg's own "==> Starting X()..." lines
  # ('prepare', 'pkgver', 'build', 'check', 'package'; a split package's
  # package_foo() is 'package'). nil for an ordinary line.
  LOG_PHASE_LINES = ['==> Installing the pacman dependencies', '==> Building in the archci-', '==> Building with '].freeze
  MAKEPKG_STEP = /\A==> Starting (prepare|pkgver|build|check|package)(?:_\S+)?\(\)\.\.\./
  def self.log_phase(line)
    return Regexp.last_match(1) if line.match(MAKEPKG_STEP)
    return nil unless line.start_with?(*LOG_PHASE_LINES)
    return 'offline' if line.include?('offline')
    return 'loopback' if line.include?('loopback')

    'online'
  end

  # ---- the log as a stream of events (SSE), live and archived alike ----
  # The framing a browser's EventSource reads: first an "event: job" with
  # the job's fields and story, then one event per journal entry (data: the
  # line's time, priority, pid, message and phase; id: the entry's journal
  # cursor, so a reconnecting reader resumes from Last-Event-ID), and, once
  # the job has finished, "event: end" with its state, the first error's
  # index and its rc and packages. sse_events gives the lines for a slice of
  # entries; a live reader gets the header once, then the entries after its
  # cursor, then the end.
  def self.sse_job_event(j, entries)
    start = entries.find { |e| e['ARCHCI_EVENT'] == 'start' } || {}
    pkg = packages.find { |p| p['pkgbase'] == j['pkgbase'] }
    # ('log', the journalctl find_job adds, and the report's summary lines are not the log's business)
    job = j.except('path', 'mtime', 'error', 'last', 'log', 'origin').merge(
      'mtime' => j['mtime']&.utc&.iso8601, 'story' => story(j), 'origin' => origin(pkg) || '-',
      'host' => start['ARCHCI_HOST'], 'archci' => start['ARCHCI_VERSION'], 'invocation' => entries.first&.dig('_SYSTEMD_INVOCATION_ID')
    ).compact
    "event: job\ndata: #{JSON.generate(job)}\n\n"
  end

  def self.sse_entry(e)
    data = { 'time' => Time.at(e['__REALTIME_TIMESTAMP'].to_i / 1_000_000, e['__REALTIME_TIMESTAMP'].to_i % 1_000_000).utc.iso8601(6),
             'priority' => e['PRIORITY'], 'pid' => e['_PID'], 'message' => e['MESSAGE'], 'phase' => e['phase'],
             'event' => e['ARCHCI_EVENT'], 'package' => e['ARCHCI_PACKAGE'], 'slice' => e['ARCHCI_SLICE'] }.compact
    # the cap's marker has no cursor: no id line, rather than an empty one
    # (which would reset the browser's Last-Event-ID to "")
    e['__CURSOR'] ? "data: #{JSON.generate(data)}\nid: #{e['__CURSOR']}\n\n" : "data: #{JSON.generate(data)}\n\n"
  end

  def self.sse_end_event(j, entries, error_at)
    fin = entries.reverse_each.find { |e| e['ARCHCI_EVENT'] == 'finish' } || {}
    rc = fin['ARCHCI_RC'] || entries.last&.dig('MESSAGE')&.[](/finished with (\d+)/, 1)
    signed = entries.filter_map { |e| e['ARCHCI_PACKAGE'] if e['ARCHCI_EVENT'] == 'signed' }
    data = { 'state' => j['state'], 'error_at' => error_at, 'finished' => j['finished'], 'rc' => rc&.to_i,
             'packages' => (signed.empty? ? nil : signed) }.compact
    "event: end\ndata: #{JSON.generate(data)}\n\n"
  end

  # a finished job's log: is it whole in the journal? By the finish record
  # (ARCHCI_EVENT=finish), or an older worker's last line
  # (the record goes through the journal's native socket and can be logged
  # a line or two before a stdout line still in the pipe, so it need not be
  # the last entry)
  def self.log_complete?(entries)
    entries.last(20).any? { |e| e['ARCHCI_EVENT'] == 'finish' || e['MESSAGE'].start_with?(*BUILD_END) }
  end

  # Export the logs of finished jobs as SSE files under DIR/<repo>/<pkgbase>/
  # <version>/<arch>/<pkgbase>-<version>-<arch>-<start>-<invocation>.sse.zst
  # (start: the attempt's first entry, seconds since the epoch; invocation:
  # the build unit's _SYSTEMD_INVOCATION_ID, fresh per unit start), zstd at
  # its default level (3: a log is small, and the master is; -19 took ten
  # times the CPU for a sixth off); archci-publish moves that tree to R2
  # as <repo>/log/. Each job
  # once (exported=<file> in its file, under the queue lock), as soon as its
  # log is whole in the journal (log_complete?); a log that never completes
  # (a build killed hard) is exported as it stands settle_after seconds
  # after the report, and a job whose journal holds nothing by then is
  # marked exported=none and not asked again. Returns the count exported.
  def self.export_logs(dir, settle_after: 600, now: Time.now)
    n = 0
    %w[done failed].each do |q|
      jobs(q).each do |j|
        next if j.key?('exported') || !j['finished']

        age = now - Time.iso8601(j['finished'])
        j = j.merge('state' => q)
        entries, err, = read_entries(j)
        if entries.empty?
          mark_exported(j, 'none') if age >= settle_after
          next
        end
        next unless log_complete?(entries) || age >= settle_after

        first = entries.first
        name = "#{j['pkgbase']}-#{j['version']}-#{j['arch']}-#{first['__REALTIME_TIMESTAMP'].to_i / 1_000_000}-#{first['_SYSTEMD_INVOCATION_ID'] || 'none'}.sse"
        path = File.join(dir, j['repo'], j['pkgbase'], j['version'], j['arch'], name)
        FileUtils.mkdir_p(File.dirname(path))
        File.open("#{path}.tmp", 'w') do |f|
          f.write(sse_job_event(j, entries))
          entries.each { |e| f.write(sse_entry(e)) }
          f.write(sse_end_event(j, entries, err))
        end
        system('zstd', '-q', '--rm', '-o', "#{path}.zst", "#{path}.tmp", exception: true)
        mark_exported(j, "#{name}.zst")
        n += 1
      rescue ArgumentError
        next   # a finished= that is not a time
      end
    end
    n
  end

  # append exported=VALUE to a job file, under the queue lock (a move by a
  # retry or the pruning of done/ in between leaves nothing to mark)
  def self.mark_exported(j, value)
    File.open(File.join(home, 'lock', 'queue.lock'), File::RDWR | File::CREAT, 0o644) do |lock|
      lock.flock(File::LOCK_EX)
      File.open(j['path'], 'a') { |f| f.puts "exported=#{value}" } if File.exist?(j['path'])
    end
  end

  # what a listing says of a job in one line: its first error line, else its
  # last line (nil without a log). From the job file when the report kept
  # them ('error', 'last': archci-job report reads the journal once, so a
  # listing of hundreds of jobs does not), else from the journal now.
  def self.log_summary(j)
    return [j['error'], j['last']] if j.key?('error') || j.key?('last')
    return [nil, nil] if j['state'] == 'pending'

    lines, err, = read_log(j)
    [err && lines[err], lines.last]
  end

  BUILD_END = ['==> archci-build finished with', '==> archci-sourcer finished with'].freeze

  # the job's story in one line: state, where, when, what it had
  def self.story(j)
    max = config['ARCHCI_MAX_ATTEMPTS'].to_i
    s = case j['state']
        when 'pending'
          held = held_reason(j, packages.find { |p| p['pkgbase'] == j['pkgbase'] })
          "pending since #{j['created']}, attempt #{j['attempt'] + 1} of #{max} next#{held ? ", held: #{held}" : ''}"
        when 'running' then "running on #{j['worker']} since #{j['claimed']}, attempt #{j['attempt']} of #{max}#{j['phase'] ? ", in #{j['phase']}" : ''}"
        when 'done' then "done #{j['finished']} on #{j['worker']}, attempt #{j['attempt']}"
        when 'failed' then "failed #{j['finished']} on #{j['worker']}, attempt #{j['attempt']} of #{max}#{j['final'] ? ': gave up' : ''}"
        end
    had = []   # the source package is a fact of its own on the job page, not the story's
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
