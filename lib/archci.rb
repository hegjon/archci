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
    'ARCHCI_PKG_ALSO' => '',
    'ARCHCI_IGNOREARCH' => '1',
    'ARCHCI_MAX_ATTEMPTS' => '3',
    'ARCHCI_RELEASE_LAG_MINUTES' => '10',
    'ARCHCI_REMOTE_JOURNAL' => '/var/log/journal/remote'
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
  # POLLS (hosts/<worker>, written by every claim), from the newest stats any
  # of its workers sent: a running job's heartbeat, an idle worker's poll, or
  # the last beat a finished job kept. A worker whose last poll is older than
  # POLL_TTL is gone. The native arch is what a worker without an arch in its
  # name builds ("any" jobs are the any arch's).
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
      h['workers'] |= [j['worker']]
      h['building'] += 1 if running_now
      h['arch'] ||= (j['arch'] == 'any' ? any_arch : j['arch']) unless port
      h['vendor'] ||= j['vendor']   # constant for a host: any worker that sent it will do
      # the archci version: from the newest beat that carries one (a worker
      # still running older code sends none, and may well be the newest beat)
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
    rest = hosts.values.reject { |h| h.equal?(m) }.sort_by { |h| h['host'] }
    [m, *rest].each { |h| h['workers'].sort!; h.delete('archci_at') }
  end

  # The master's own host stats, as a worker would send them (load, mem, disk
  # of ARCHCI_HOME, cpus, vendor, archci), from lib/archci-common.sh.
  def self.master_stats
    out, status = Open3.capture2('bash', '-c', 'source "$1/lib/archci-common.sh"; archci_worker_stats "$ARCHCI_HOME"', '_', ROOT)
    return {} unless status.success?

    out.split.to_h { |kv| kv.split('=', 2) }.slice(*HOST_STATS)
  end

  # The packages in the PKGBUILD repository clone, from archci-pkgs (which
  # caches them per clone HEAD): name (the job's pkgbase), version, commit,
  # arches, profile, source and whether package.json skips the build. Empty
  # when the clone does not exist yet (archci-scan creates it).
  def self.packages(refresh: false)
    @packages = nil if refresh
    @packages ||= begin
      out, status = Open3.capture2(File.join(ROOT, 'master', 'archci-pkgs'))
      if status.success?
        out.lines.filter_map do |line|
          name, version, commit, arch, profile, source, build, arch_repo, pkgnames, deps = line.split
          next unless build

          { 'pkgbase' => name, 'version' => version, 'commit' => commit, 'arches' => arch.split(','),
            'profile' => profile, 'source' => source, 'skip' => build == 'skip', 'arch_repo' => arch_repo.to_s,
            'pkgnames' => (pkgnames || name).split(','), 'deps' => (deps == '-' ? [] : deps.to_s.split(',')) }
        end
      else
        []
      end
    end
  end

  # Packages whose PKGBUILD version is not the one we last built, in claim
  # order: the farm's own packages (ARCHCI_PKG_ALSO, i.e. archci) first, then
  # packages whose dependencies from this repository are all built, at their
  # current version, before those still waiting for one (so a library goes
  # before what links it, and a build is not tried before it can succeed:
  # an update waiting for a library's update comes after the whole backlog);
  # within those, updates of packages we already publish before the
  # never-built backlog; then by
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

    sources = cfg['ARCHCI_PKG_SOURCES'].to_s.split
    also = cfg['ARCHCI_PKG_ALSO'].to_s.split   # built whatever their source
    ignorearch = cfg['ARCHCI_IGNOREARCH'] != '0'
    candidates = packages.reject do |p|
      p['skip'] || (!sources.empty? && !sources.include?(p['source']) && !also.include?(p['pkgbase']))
    end

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
    # is waited for: the dependent's new version usually needs it), and long
    # enough ago for the signer to have released it (ARCHCI_RELEASE_LAG_MINUTES:
    # the chroot installs from the release); one that gave up at its current
    # commit is not waited for (the chroot falls back on the mirrors' copy,
    # if any). The built names come from one listing per arch, the versions
    # from the built records (cached): the check runs for every dependency
    # of every package on every archci top frame.
    by_base = candidates.to_h { |p| [p['pkgbase'], p] }
    built_names = Hash.new do |h, a|
      dir = File.join(home, 'built', "#{repo}-#{a}")
      h[a] = File.directory?(dir) ? Dir.children(dir).to_set : Set.new
    end
    released_before = Time.now - cfg['ARCHCI_RELEASE_LAG_MINUTES'].to_i * 60
    current = Hash.new do |h, (dep_base, a)|
      path = File.join(home, 'built', "#{repo}-#{a}", dep_base)
      h[[dep_base, a]] = built_names[a].include?(dep_base) &&
                         built_record(path)&.first == by_base[dep_base]['version'] && File.mtime(path) <= released_before
    end
    dep_built = lambda do |dep_base, a|
      current[[dep_base, a]] || current[[dep_base, 'any']] ||
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
        entry = { 'repo' => repo, 'arch' => job_arch, 'pkgbase' => p['pkgbase'], 'version' => p['version'],
                  'commit' => p['commit'], 'profile' => p['profile'], 'prio' => built ? 1 : 5, 'waiting' => waiting, 'expected' => expected,
                  'rank' => [also.include?(p['pkgbase']) ? 0 : 1, waiting.empty? ? 0 : 1, built ? 0 : 1, origin_rank(p), any ? 1 : 0, p['pkgbase']] }
        (built ? updates : backlog) << entry
      end
    end
    ordered = (updates + backlog).sort_by { |e| e['rank'] }
    limit ? ordered.first(limit) : ordered
  end

  # The dependencies from this repository a job for pkgbase on job_arch
  # ("any" for an any package) still waits for (see outstanding); [] when
  # none, or when the package is not outstanding at all.
  def self.waiting_for(pkgbase, job_arch)
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
    outstanding = self.outstanding
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
      'tracked' => sets.to_h,
      'built' => sets.to_h { |key, _| [key, Dir.glob(File.join(home, 'built', key, '*')).size] },
      'hosts' => hosts(running, recent, Dir.glob(File.join(home, 'hosts', '*')).filter_map { |p| read_job(p) }, now),
      'signer' => signer,
      'running' => running,
      'failed' => failed
    }
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
