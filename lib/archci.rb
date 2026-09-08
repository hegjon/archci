# frozen_string_literal: true

# archci.rb -- shared helpers for the ruby parts of archci (scan, status).
# Mirrors archci-common.sh: same config file, same job file format.
require 'etc'
require 'json'
require 'open3'
require 'time'

module Archci
  CONF = ENV.fetch('ARCHCI_CONF', '/etc/archci/archci.conf')

  DEFAULTS = {
    'ARCHCI_HOME' => '/var/lib/archci',
    'ARCHCI_ARCH' => Etc.uname[:machine],
    'ARCHCI_PKGBUILDS_URL' => 'https://github.com/hegjon/omarchy-pkgs.git',
    'ARCHCI_PKGBUILDS_BRANCH' => 'master',
    'ARCHCI_PKGBUILDS_DIR' => 'pkgbuilds',
    'ARCHCI_REPO' => 'omarchy',
    'ARCHCI_PKG_SOURCES' => '',
    'ARCHCI_PKG_ALSO' => '',
    'ARCHCI_IGNOREARCH' => '1',
    'ARCHCI_MAX_ATTEMPTS' => '3',
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
      next unless (m = line.match(/\A([a-z]+)=(.*)\z/m))

      job[m[1]] = m[2].chomp
    end
    job['attempt'] = job.fetch('attempt', '0').to_i
    job['mtime'] = File.mtime(path)
    job
  rescue Errno::ENOENT
    nil # raced with a claim/report, ignore
  end

  def self.jobs(queue_name)
    Dir.glob(File.join(queue(queue_name), '*.job')).sort.filter_map { |p| read_job(p) }
  end

  # Arches the master builds for, and the arch whose workers build "any"
  # packages (pooled for every arch).
  def self.arches
    (config['ARCHCI_ARCHES'] || config['ARCHCI_ARCH']).split
  end

  def self.any_arch
    config['ARCHCI_ANY_ARCH'] || arches.first
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
          name, version, commit, arch, profile, source, build, arch_repo = line.split
          next unless build

          { 'pkgbase' => name, 'version' => version, 'commit' => commit, 'arches' => arch.split(','),
            'profile' => profile, 'source' => source, 'skip' => build == 'skip', 'arch_repo' => arch_repo.to_s }
        end
      else
        []
      end
    end
  end

  # Packages whose PKGBUILD version is not the one we last built, in claim
  # order: the farm's own packages (ARCHCI_PKG_ALSO, i.e. archci) first, then
  # updates of packages we already publish before the never-built backlog, and
  # within those by origin: Arch's core, then extra, then multilib, then the
  # repository's local packages, then those from the AUR; an arch's own
  # packages before the any packages; alphabetically last.
  # Nothing is stored; this is computed from the package index, built/ and the
  # queue on every call.
  #   arch:  only jobs a worker of this arch may build (its own, plus "any" if
  #          it is ARCHCI_ANY_ARCH); nil for every enabled arch
  #   limit: return only this many candidates
  def self.outstanding(arch: nil, limit: nil)
    cfg = config
    repo = cfg['ARCHCI_REPO']
    running = jobs('running').to_h { |j| [[j['repo'], j['pkgbase'], j['arch']], true] }
    queued = Hash.new { |h, k| h[k] = [] } # pending or failed, by commit
    %w[pending failed].each do |q|
      jobs(q).each { |j| queued[[j['repo'], j['pkgbase'], j['arch']]] << j['commit'] }
    end

    sources = cfg['ARCHCI_PKG_SOURCES'].to_s.split
    also = cfg['ARCHCI_PKG_ALSO'].to_s.split   # built whatever their source
    ignorearch = cfg['ARCHCI_IGNOREARCH'] != '0'
    candidates = packages.reject do |p|
      p['skip'] || (!sources.empty? && !sources.include?(p['source']) && !also.include?(p['pkgbase']))
    end

    # An arch-independent package is one job, for workers of the any arch,
    # and is pooled for every arch; those come after the arch's own packages.
    # Anything else is offered to every enabled arch: a port arch builds with
    # --ignorearch (ARCHCI_IGNOREARCH) unless told to honour the arch array.
    per_arch, any_pkgs = candidates.partition { |p| p['arches'] != ['any'] }
    updates = []
    backlog = []
    (arch ? [arch] : arches).each do |a|
      list = a == any_arch ? per_arch + any_pkgs : per_arch
      list.each do |p|
        any = p['arches'] == ['any']
        job_arch = any ? 'any' : a
        next if !any && !ignorearch && !p['arches'].include?(a)

        # built record: "version commit" and, for an any package, the arches it
        # was pooled for; an arch enabled since makes the package outstanding again
        built_file = File.join(home, 'built', "#{repo}-#{job_arch}", p['pkgbase'])
        built, _commit, pooled = File.exist?(built_file) ? File.read(built_file).split : []
        next if built == p['version'] && (!any || (arches - pooled.to_s.split(',')).empty?)
        next if running[[repo, p['pkgbase'], job_arch]]                 # one build per package and arch at a time
        next if queued[[repo, p['pkgbase'], job_arch]].include?(p['commit']) # queued, in retry backoff, or given up

        entry = { 'repo' => repo, 'arch' => job_arch, 'pkgbase' => p['pkgbase'], 'version' => p['version'],
                  'commit' => p['commit'], 'profile' => p['profile'], 'prio' => built ? 1 : 5,
                  'rank' => [also.include?(p['pkgbase']) ? 0 : 1, built ? 0 : 1, origin_rank(p), any ? 1 : 0, p['pkgbase']] }
        (built ? updates : backlog) << entry
      end
    end
    ordered = (updates + backlog).sort_by { |e| e['rank'] }
    limit ? ordered.first(limit) : ordered
  end

  # Claim order among packages of one class: Arch's core before extra before
  # multilib, then this repository's own (local) packages, then AUR ones.
  ORIGIN_RANK = { %w[arch core] => 0, %w[arch extra] => 1, %w[arch multilib] => 2 }.freeze
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
