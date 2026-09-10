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
# and the master has one CPU). It is read for one thing, each running job's
# last output line: JournalFollow keeps one "journalctl -f" for the session,
# read by a thread that remembers the newest line per build unit as it
# arrives; a frame only renders. A job seen for the first time gets one look
# of its own, backwards through the unit's index (a long build has 100k+
# lines behind it), never through the journal as a whole. The phase comes
# with the worker's heartbeat (archci_phase_filter), not from here.

# dir nil: the caller names the file(s) itself (--file)
def journal_entries(dir, *args)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  out, = Open3.capture2('journalctl', *(dir ? ['-D', dir] : []), '--no-pager', '-o', 'json',
                        '--output-fields=MESSAGE,_SYSTEMD_UNIT', *args, err: File::NULL)
  # ARCHCI_TOP_DEBUG=1: every journalctl call and what it cost, on stderr
  if ENV['ARCHCI_TOP_DEBUG']
    warn format('%6.2fs journalctl %s', Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, args.map { |a| a.to_s[0, 60] }.join(' ')[0, 200])
  end
  # journalctl writes UTF-8 whatever the locale (a unit's may be none: US-ASCII)
  out.force_encoding(Encoding::UTF_8).each_line.filter_map { |l| parse_entry(l) }
end

def parse_entry(line)
  JSON.parse(line.scrub)
rescue JSON::ParserError, EncodingError
  nil
end

# the entry's unit, as unit_name spells it (the journal appends .service)
def unit_of(entry)
  entry['_SYSTEMD_UNIT'].to_s.delete_suffix('.service')
end

def message_of(entry)
  m = entry['MESSAGE']
  (m.is_a?(Array) ? m.pack('C*').force_encoding('UTF-8') : m.to_s).strip
end

# One journalctl -f for the session; last(jobs) answers from what it has
# streamed, after a first look at any job it has not seen.
class JournalFollow
  def initialize(dir)
    @dir = dir
    @lock = Mutex.new
    @last = {}
    @seen = {}
    @pid = nil
    @reader = Thread.new { follow }
  end

  # journalctl -f, starting with the last 100 entries; started again should
  # it end (it survives the journal's own file rotation, but not much else)
  def follow
    loop do
      begin
        Open3.popen2('journalctl', '-D', @dir, '--no-pager', '-o', 'json', '--output-fields=MESSAGE,_SYSTEMD_UNIT',
                     '-f', '-n', '100', err: File::NULL) do |_stdin, out, waiter|
          @pid = waiter.pid
          out.each_line do |line|
            e = parse_entry(line.force_encoding(Encoding::UTF_8)) or next
            u = unit_of(e)
            next unless u.start_with?('archci-build@')

            msg = message_of(e)
            @lock.synchronize { @last[u] = msg }
          end
        end
      rescue StandardError
        nil
      end
      @pid = nil
      sleep 2
    end
  end

  def stop
    @reader.kill
    Process.kill('TERM', @pid) if @pid
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  # jobs: [[unit, claimed], ...] -> { unit => last line }
  def last(jobs)
    # first sight of a job: its last line so far, from the journal files
    # written to since it was claimed, one entry backwards through the
    # unit's index; what the stream has meanwhile is not overwritten
    files = Dir.glob(File.join(@dir, '*.journal'))
    jobs.reject { |u, _| @seen[u] }.each do |u, claimed|
      since = claimed ? Time.iso8601(claimed) : Time.at(0)
      sel = files.select { |f| File.mtime(f) >= since }.flat_map { |f| ['--file', f] }
      @seen[u] = true
      next if sel.empty?

      l = journal_entries(nil, *sel, '-u', u, '-n', '1', '--reverse').first
      @lock.synchronize { @last[u] ||= message_of(l) } if l
    end
    @lock.synchronize { jobs.to_h { |u, _| [u, @last[u].to_s] } }
  rescue StandardError
    {}
  end
end

# top's looks on a terminal: bold headers and figures. Plain when the output
# is not a terminal (--once into a pipe, the tests).
STYLE = $stdout.tty?
def bold(s) = STYLE ? "\e[1m#{s}\e[0m" : s

# journal: a JournalFollow for PHASE and the last output line, nil for
# none; snap: a snapshot already taken; hint: the quit hint in the title
# (not when the frame is printed once)
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
  # the signer, as seen through R2 by archci-signer-status: what is signed
  # and released per arch on one line, what waits unsigned in staging on
  # the next
  if (s = snap['signer'])
    rel = (s['release'] || {}).map { |a, r| r['updated'] ? "#{a} #{bold(r['packages'])} pkg" : "#{a} unreachable" }
    out << "released: #{rel.join('  ')}" unless rel.empty?
    st = s['staging'] || {}
    line = format('unsigned: %s pkg in staging%s', bold(st['waiting'].to_i), st['oldest_s'] ? " (oldest #{elapsed(st['oldest_s'])})" : '')
    line += "   [status #{elapsed(s['age_s'])} old]" if s['age_s'] > 600
    out << line
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

  out << bold(format('%-8s %-19s %-7s %3s %4s %5s %5s %5s %5s  %-8s %-8s %s', 'ELAPSED', 'WORKER', 'ARCH', 'ATT', 'HB', 'LOAD', 'DISK', 'MEM', 'PEAK', 'PHASE', 'SOURCE', 'PACKAGE  | last output')[0, width])
  # a MiB count in five characters: 458M up to 999M, then 1.2G, then 100G
  mem = lambda do |v|
    return '-' if v.nil?

    g = v.to_i / 1024.0
    if v.to_i <= 999 then "#{v}M"
    elsif g < 99.95 then format('%.1fG', g)
    else format('%.0fG', g)
    end
  end
  # the build tree: KiB from the worker (raw du -sk; 5.0G before 0.3.30, shown as is)
  tree = ->(v) { v.nil? ? '-' : (v =~ /\A\d+\z/ ? mem[(v.to_i / 1024.0).round] : v) }
  # cores in use: the CPU time used over the wall time it took, both raw
  # from the worker (cpu= cores from a worker before 0.3.30), shown like a load
  cores = lambda do |j|
    if j['cpu_us'] && j['cpu_dt'].to_i.positive? then load[format('%.2f', j['cpu_us'].to_f / j['cpu_dt'].to_f)]
    else load[j['cpu']]
    end
  end
  # the last output line from the journal follower, '-' without one: the
  # first frame, --once, or --no-journal
  lasts = journal ? journal.last(running.map { |j| [unit_name(j), j['claimed']] }) : {}
  # by host, its native workers first, then per emulated arch, instance
  # numbers as numbers: host-1, host-3, host-aarch64-1, host-riscv64-2
  running.sort_by do |j|
    host, port = Archci.worker_host(j['worker'].to_s)
    [host, port ? 1 : 0, port.to_s, j['worker'].to_s[/(\d+)\z/, 1].to_i]
  end.each do |j|
    since = j['claimed'] ? now - Time.iso8601(j['claimed']) : j['heartbeat_age_s']
    hb_s = j['heartbeat_age_s']
    hb = hb_s <= 99 ? "#{hb_s}s" : "#{(hb_s / 60.0).round}m"   # seconds while they fit in two digits, then minutes
    last = lasts[unit_name(j)].to_s
    phase = j['phase'].to_s   # from the worker's heartbeat
    line = format('%-8s %-19s %-7s %3d %4s %5s %5s %5s %5s  %-8s %-8s %s %s', hms(since), short_worker(j['worker'])[0, 19], j['arch'], j['attempt'], hb,
                  cores[j], tree[j['build']], mem[j['rss']], mem[j['peak']],
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
