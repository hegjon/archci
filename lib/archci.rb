# frozen_string_literal: true

# archci.rb -- shared helpers for the ruby parts of archci (scan, status).
# Mirrors archci-common.sh: same config file, same job file format.
require 'json'
require 'time'

module Archci
  CONF = ENV.fetch('ARCHCI_CONF', '/etc/archci/archci.conf')

  DEFAULTS = {
    'ARCHCI_HOME' => '/var/lib/archci',
    'ARCHCI_ARCH' => 'x86_64',
    'ARCHCI_REPOS' => 'core extra',
    'ARCHCI_STATE_URL' => 'https://gitlab.archlinux.org/archlinux/packaging/state.git',
    'ARCHCI_MAX_ATTEMPTS' => '3'
  }.freeze

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

  # Packages whose released commit is not the one we last built, in claim
  # order: updates of packages we already publish first, then the backlog.
  # Nothing is stored; this is computed from state/, built/ and the queue on
  # every call (about 13,000 small files for core+extra, well under a second).
  #   limit: stop as soon as this many candidates are known
  def self.outstanding(limit: nil)
    cfg = config
    arch = cfg['ARCHCI_ARCH']
    state = File.join(home, 'state')
    running = jobs('running').to_h { |j| [[j['repo'], j['pkgbase']], true] }
    queued = Hash.new { |h, k| h[k] = [] } # pending or failed, by commit
    %w[pending failed].each do |q|
      jobs(q).each { |j| queued[[j['repo'], j['pkgbase']]] << j['commit'] }
    end

    updates = []
    backlog = []
    cfg['ARCHCI_REPOS'].split.each do |repo|
      dir = File.join(state, "#{repo}-#{arch}")
      next unless File.directory?(dir)

      Dir.children(dir).sort.each do |name|
        pkgbase, version, tag, commit = File.read(File.join(dir, name)).split
        next unless pkgbase == name && version && tag && commit

        built_file = File.join(home, 'built', "#{repo}-#{arch}", pkgbase)
        built = File.exist?(built_file) ? File.read(built_file).strip : nil
        next if built == "#{version} #{commit}"
        next if running[[repo, pkgbase]]            # one build per package at a time
        next if queued[[repo, pkgbase]].include?(commit) # queued, in retry backoff, or given up

        entry = { 'repo' => repo, 'pkgbase' => pkgbase, 'version' => version, 'tag' => tag,
                  'commit' => commit, 'prio' => built ? 1 : 5 }
        (built ? updates : backlog) << entry
        return updates if limit && updates.size >= limit
      end
    end
    limit ? (updates + backlog).first(limit) : updates + backlog
  end

  def self.log(msg)
    warn "#{File.basename($PROGRAM_NAME)}: #{msg}"
    return if ENV['JOURNAL_STREAM']

    system('logger', '-t', File.basename($PROGRAM_NAME), '--', msg, exception: false)
  end

  # Atomic write: the queue is only ever observed through complete files.
  def self.write_atomic(path, content)
    tmp = "#{path}.tmp"
    File.write(tmp, content)
    File.rename(tmp, path)
  end
end
