# frozen_string_literal: true

# archci-frame.rb -- the farm as one screen: the header (queue, built, signer),
# the hosts table, the jobs table and the failed list, from Archci.snapshot,
# for archci-top (redrawn on an interval with the workers' journals, or
# printed once). Styled only on a terminal.
require_relative 'archci'
require 'open3'

def elapsed(seconds)
  s = seconds.to_i
  return format('%dd%02dh', s / 86_400, s % 86_400 / 3600) if s >= 86_400
  return format('%dh%02dm', s / 3600, s % 3600 / 60) if s >= 3600

  format('%dm%02ds', s / 60, s % 60)
end

# the ELAPSED column: hh:mm:ss (hours keep counting past a day: 26:03:04)
def hms(seconds)
  s = seconds.to_i
  format('%02d:%02d:%02d', s / 3600, s % 3600 / 60, s % 60)
end

# A worker id with an emulated arch in it, host-aarch64-2, shown as host-a2:
# the ARCH column says which arch; the letter keeps it apart from host-2.
def short_worker(worker)
  host, port = Archci.worker_host(worker.to_s)
  port ? "#{host}-#{port[0]}#{worker[/(\d+)\z/, 1]}" : worker
end

# The build unit's name on the worker (archci-worker's rule) and, from its
# journal streamed to the master, the makepkg phase and last output line.
def unit_name(j)
  "archci-build@#{"#{j['repo']}-#{j['pkgbase']}-#{j['version']}-#{j['arch']}-a#{j['attempt']}".gsub(/[^A-Za-z0-9:_.-]/, '_')}"
end

# The remote journal holds every worker's every build (a gigabyte or more,
# and the master has one CPU), so a frame costs two bounded reads whatever
# the number of jobs: the newest lines of the newest journal file, for every
# job's last output line, and the phase markers ("==> Starting build()...",
# "==> Making package: ...") written since the previous frame's cursor. A job seen
# for the first time gets one walk of its own, --since its claim, for the
# phase it is in (a long build has 100k+ lines behind it) and, when it is
# quiet, its last line; both are remembered.
MARKER = '^==> (Starting|Making package|Installing missing|Retrieving|Validating|Verifying|Extracting|Creating|Updating|Synchronizing|archci-build finished)'
TAIL_LINES = 1500
JSTATE = { phase: {}, last: {}, seen: {}, cursor: nil }

# dir nil: the caller names the file(s) itself (--file)
def journal_entries(dir, *args)
  out, = Open3.capture2('journalctl', *(dir ? ['-D', dir] : []), '--no-pager', '-o', 'json',
                        '--output-fields=MESSAGE,_SYSTEMD_UNIT', *args, err: File::NULL)
  # journalctl writes UTF-8 whatever the locale (a unit's may be none: US-ASCII)
  out.force_encoding(Encoding::UTF_8).each_line.filter_map do |l|
    JSON.parse(l.scrub)
  rescue JSON::ParserError, EncodingError
    nil
  end
end

# the entry's unit, as unit_name spells it (the journal appends .service)
def unit_of(entry)
  entry['_SYSTEMD_UNIT'].to_s.delete_suffix('.service')
end

def message_of(entry)
  m = entry['MESSAGE']
  (m.is_a?(Array) ? m.pack('C*').force_encoding('UTF-8') : m.to_s).strip
end

# The job's phase in eight characters, from its marker's first word: the
# chroot's pacman, then makepkg's steps, then the worker uploading results
# (archci-build's last line; the journal shows nothing more until the
# worker's next claim).
PHASES = {
  'synchronizing' => 'sync', 'updating' => 'update', 'installing' => 'deps', 'making' => 'start',
  'retrieving' => 'download', 'validating' => 'sums', 'verifying' => 'verify', 'extracting' => 'extract',
  'prepare' => 'prepare', 'pkgver' => 'pkgver', 'build' => 'build', 'check' => 'check', 'package' => 'package',
  'creating' => 'compress', 'archci-build' => 'upload'
}.freeze

def phase_of(message)
  word = message.sub(/^==> Starting ([\w-]+)\(\).*/, '\1').sub(/^==> /, '').split(/[ :(]/).first.to_s.downcase
  PHASES[word] || (word.start_with?('package_') ? 'package' : word[0, 8])
end

# jobs: [[unit, claimed], ...] -> { unit => [phase, last line] }
def journal_tails(dir, jobs)
  return {} unless dir && File.directory?(dir)

  units = jobs.map(&:first)
  if JSTATE[:cursor]
    journal_entries(dir, "--after-cursor=#{JSTATE[:cursor]}", '-g', MARKER).each do |e|
      JSTATE[:phase][unit_of(e)] = phase_of(message_of(e)) if units.include?(unit_of(e))
    end
  end
  # the newest lines live in the newest file; asking the whole directory for
  # its tail makes journalctl open and order every file first (seconds)
  newest = Dir.glob(File.join(dir, '*.journal')).max_by { |f| File.mtime(f) }
  tail = newest ? journal_entries(nil, '--file', newest, '-n', TAIL_LINES.to_s) : []
  tail.each { |e| JSTATE[:last][unit_of(e)] = message_of(e) if units.include?(unit_of(e)) }
  JSTATE[:cursor] = tail.last['__CURSOR'] if tail.last
  # first sight of a job: its phase so far and, if the tail missed it, its last line
  jobs.reject { |u, _| JSTATE[:seen][u] }.map do |u, claimed|
    Thread.new do
      since = claimed ? ['--since', claimed] : []
      m = journal_entries(dir, '-u', u, *since, '-n', '1', '-g', MARKER).last
      JSTATE[:phase][u] = phase_of(message_of(m)) if m
      l = JSTATE[:last][u] || journal_entries(dir, '-u', u, *since, '-n', '1').last
      JSTATE[:last][u] = message_of(l) if l.is_a?(Hash)
      JSTATE[:seen][u] = true
    end
  end.each(&:join)
  units.to_h { |u| [u, [JSTATE[:phase][u].to_s, JSTATE[:last][u].to_s]] }
rescue StandardError
  {}
end

# top's looks on a terminal: bold headers and figures. Plain when the output
# is not a terminal (--once into a pipe, the tests).
STYLE = $stdout.tty?
def bold(s) = STYLE ? "\e[1m#{s}\e[0m" : s

# journal: the remote journal directory for PHASE and the last output line,
# nil for none; snap: a snapshot already taken; hint: the quit hint in the
# title (not when the frame is printed once)
def frame(journal, snap = nil, hint: true)
  now = Time.now
  width = (ENV['COLUMNS'] || `tput cols 2>/dev/null`.to_i.nonzero? || 120).to_i
  snap ||= Archci.snapshot(now)
  repo = snap['repo']
  counts = snap['queue']
  running = snap['running']
  failed = snap['failed'].first(5)

  out = []
  out << format('archci-top  %s   pkgbuilds -> [%s]   arches: %s%s', now.strftime('%H:%M:%S'), repo,
                snap['arches'].join(' '), hint ? '   (q or Esc quits)' : '')
  out << format('queue: pending %s  running %s  failed %s  done %s (%s in the last hour)    outstanding: %s update(s), %s unbuilt',
                *[counts['pending'], counts['running'], counts['failed'], counts['done'], snap['done_last_hour'],
                  snap['outstanding']['updates'], snap['outstanding']['backlog']].map { |n| bold(n) })
  out << format('built: %s', snap['built'].map { |k, n| "#{k.delete_prefix("#{repo}-")} #{bold(n)}/#{snap['tracked'][k]}" }.join('  '))
  # the signer, as seen through R2 by archci-signer-status: what waits
  # unsigned in staging on one line, what is signed and released per arch
  # on the next
  if (s = snap['signer'])
    st = s['staging'] || {}
    line = format('unsigned: %s pkg in staging%s', bold(st['waiting'].to_i), st['oldest_s'] ? " (oldest #{elapsed(st['oldest_s'])})" : '')
    line += "   [status #{elapsed(s['age_s'])} old]" if s['age_s'] > 600
    out << line
    rel = (s['release'] || {}).map { |a, r| r['updated'] ? "#{a} #{bold(r['packages'])} pkg" : "#{a} unreachable" }
    out << "signed  : #{rel.join('  ')}" unless rel.empty?
  end
  out << ''

  # hosts: one row each, its workers grouped, from the newest heartbeat any
  # of them sent (an idle host shows the last beat its finished jobs kept)
  out << bold(format('%-22s %-13s %-7s %5s %5s %5s %7s %7s %6s  %s', 'HOST', 'VENDOR', 'ARCH', 'LOAD', '%DISK', '%MEM', 'THREADS', 'WORKERS', 'ACTIVE', 'ARCHCI'))
  # the load in five characters: as sent (two decimals) below 100, whole from 100
  load = ->(l) { l.nil? ? '-' : (l.to_f < 100 ? l : format('%.0f', l.to_f)) }
  snap['hosts'].each do |h|
    out << format('%-22s %-13s %-7s %5s %5s %5s %7s %7d %6d  %s', h['host'], (h['vendor'] || '-')[0, 13], h['arch'] || '-', load[h['load']],
                  h['disk'] || '-', h['mem'] || '-', h['cpus'] || '-', h['workers'].size, h['building'], h['archci'] || '-')
  end
  out << ''

  out << bold(format('%-8s %-19s %-7s %3s %4s %5s %5s %5s %5s  %-8s %-8s %s', 'ELAPSED', 'WORKER', 'ARCH', 'ATT', 'HB', '%CPU', 'DISK', 'MEM', 'PEAK', 'PHASE', 'SOURCE', 'PACKAGE  | last output')[0, width])
  # a MiB count in five characters: 458M up to 999M, then 1.2G
  mem = ->(v) { v.nil? ? '-' : (v.to_i > 999 ? format('%.1fG', v.to_i / 1024.0) : "#{v}M") }
  # PHASE and the last output line from the journal (journal_tails), '-'
  # while it has not been read: the first frame, or --no-journal
  tails = journal_tails(journal, running.map { |j| [unit_name(j), j['claimed']] })
  # by host, its native workers first, then per emulated arch, instance
  # numbers as numbers: host-1, host-3, host-aarch64-1, host-riscv64-2
  running.sort_by do |j|
    host, port = Archci.worker_host(j['worker'].to_s)
    [host, port ? 1 : 0, port.to_s, j['worker'].to_s[/(\d+)\z/, 1].to_i]
  end.each do |j|
    since = j['claimed'] ? now - Time.iso8601(j['claimed']) : j['heartbeat_age_s']
    hb_s = j['heartbeat_age_s']
    hb = hb_s <= 99 ? "#{hb_s}s" : "#{(hb_s / 60.0).round}m"   # seconds while they fit in two digits, then minutes
    phase, last = tails[unit_name(j)] || ['', '']
    line = format('%-8s %-19s %-7s %3d %4s %5s %5s %5s %5s  %-8s %-8s %s %s', hms(since), short_worker(j['worker'])[0, 19], j['arch'], j['attempt'], hb,
                  j['cpu'] ? (j['cpu'].to_f * 100).round.to_s : '-', j['build'] || '-', mem[j['rss']], mem[j['peak']],
                  phase.empty? ? '-' : phase[0, 8], (j['origin'] || '-')[0, 8], "#{j['pkgbase']} #{j['version']}", "| #{last.empty? ? '-' : last}")
    out << line[0, width]
  end
  out << '(nothing running)' if running.empty?
  out << ''
  unless failed.empty?
    out << bold(format('%-34s %-7s  %-17s %8s  %7s  %s', 'FAILED (newest first)', 'ARCH', 'WORKER', 'FAILURES', 'GAVE UP', 'LAST FAILURE'))
    failed.each do |j|
      out << format('%-34s %-7s  %-17s %8d  %7s  %s', "#{j['pkgbase']} #{j['version']}"[0, 34], j['arch'], short_worker(j['worker']),
                    j['attempt'], j['final'] ? 'yes' : '-', j['finished'])[0, width]
    end
  end
  out
end
