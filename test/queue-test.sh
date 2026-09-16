#!/bin/bash
# shellcheck disable=SC2010  # test assertions use ls on controlled temp fixtures
# queue-test.sh -- the master's job queue: just-in-time claim, heartbeats and
# what archci-top shows from them, report success/failure, retries, giving up,
# housekeeping (stale, superseded, old polls), manual enqueue, retry --all and
# a worker that claims while its job still runs.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
source "$here/fixture.sh"
"$scan" >/dev/null

echo "--- claim picks the next outstanding package just in time"
out=$("$job" claim worker-1 x86_64)
id=$(sed -n 's/^id=//p' <<<"$out")
[[ $id == 5-*-omarchy,acl,1:2.3.2-1,x86_64 ]] || fail "expected acl first (sorted), got $id"
grep -q "^arch=x86_64$" <<<"$out" || fail "job arch should be the claiming worker's"
! "$job" claim worker-1 2>/dev/null || fail "a claim must name its arch"
grep -q '^profile=extra$' <<<"$out" || fail "job carries the build profile"
grep -q "^commit=$(pkgcommit acl)$" <<<"$out" || fail "job pins the package directory's commit"
[[ $("$next") == "5 omarchy x86_64 libsigc++ "* ]] || fail "a running package must not be offered again"
grep -q '^attempt=1$' <<<"$out" || fail "attempt should be 1"
[[ -f $ARCHCI_HOME/queue/running/$id.job ]] || fail "job not in running/"

echo "--- heartbeats carry the host's and the job's stats; archci-top shows them"
"$job" heartbeat "$id" "worker=$(owner "$id")"
"$job" heartbeat "$id" "worker=$(owner "$id")" load=1.50 mem=42 disk=61 cpus=4
grep -q '^load=1.50$' "$ARCHCI_HOME/queue/running/$id.job" || fail "heartbeat stats not kept with the job"
"$job" heartbeat "$id" "worker=$(owner "$id")" load=0.10 mem=40 disk=61 cpus=4 vendor=DigitalOcean cpu_us=3700000 cpu_dt=1000000 rss=1840 peak=2100 build=5242880
grep -q '^build=5242880$' "$ARCHCI_HOME/queue/running/$id.job" || fail "job stats not kept"
(( $(grep -c '^load=' "$ARCHCI_HOME/queue/running/$id.job") == 1 )) || fail "heartbeat stats must be replaced, not appended"
# shellcheck disable=SC2016  # a literal shell-looking stat, meant to be rejected
! "$job" heartbeat "$id" "worker=$(owner "$id")" 'load=$(rm -rf /)' 2>/dev/null || fail "a malformed stat must be refused"
! "$job" heartbeat "9-1-omarchy,nope,1-1,x86_64" 2>/dev/null || fail "heartbeat of unknown job must fail"
me=$(cut -d. -f1 /proc/sys/kernel/hostname)
"$top" | sed -n '/^HOST/{n;p}' | grep "^$me .*  -  *-  " >/dev/null || fail "the master itself must be the first host row, with - for workers and active: $("$top" | sed -n '/^HOST/{n;p}')"
"$top" | grep "^worker  *DigitalOcean  *x86_64  *0.10 .* 4  *1  *1  -$" >/dev/null || fail "archci-top must show the host's arch, vendor, stats, threads, worker count, active workers and a dash for an unknown archci version: $("$top" | grep ^worker)"
# a second worker of the host says which archci it runs; a newer beat from
# the first, which says nothing, must not hide that
ARCHCI_PKG_SOURCES=nothing "$job" claim worker-2 x86_64 load=0.20 mem=40 disk=61 cpus=4 archci=0.3.19-1 | grep . >/dev/null && fail "worker-2's poll must get no job with no sources enabled"
"$job" heartbeat "$id" "worker=$(owner "$id")" load=0.10 mem=40 disk=61 cpus=4 vendor=DigitalOcean cpu_us=3700000 cpu_dt=1000000 rss=1840 peak=2100 build=5242880
"$top" | grep "^worker  *DigitalOcean  *x86_64  *0.10 .* 4  *2  *1  0.3.19-1$" >/dev/null || fail "the archci version must come from whichever worker sent it: $("$top" | grep ^worker)"
# the signing pipeline as the master sees it: what the databases archci-publish
# indexed hold (the released listings) and what waits in the pool for the signer
mkdir -p "$ARCHCI_HOME/released" "$ARCHCI_HOME/repo/omarchy/os/x86_64"; seq 63 | sed 's/^/p&-1-1 /' >"$ARCHCI_HOME/released/omarchy-x86_64"
w1=$(mkpkg "$ARCHCI_HOME/repo/omarchy/os/x86_64" waiting 1-1); touch -d '-90 seconds' "$w1"
w2=$(mkpkg "$ARCHCI_HOME/repo/omarchy/os/x86_64" parked 1-1); : >"$w2.rejected"
"$top" | grep "^unsigned: 1 pkg in the pool (oldest 1m[23][0-9]s)   rejected by the signer: 1$" >/dev/null || fail "archci-top must show what waits for the signer, the oldest's age and the rejected: $("$top" | grep ^unsigned)"
ARCHCI_ARCHES="x86_64 aarch64" "$top" | grep "^released: x86_64 63 pkg  aarch64 none yet$" >/dev/null || fail "the released line must show the databases per arch: $(ARCHCI_ARCHES="x86_64 aarch64" "$top" | grep ^released)"
rm -f "$w1" "$w2" "$w2.rejected"; rm -r "$ARCHCI_HOME/released"
"$job" heartbeat "$id" "worker=$(owner "$id")" load=0.10 mem=40 disk=61 cpus=4 vendor=DigitalOcean cpu_us=3700000 cpu_dt=1000000 rss=104858 peak=204800 build=134217728
COLUMNS=200 "$top" | grep "  3.70  128G  102G  200G  -        arch     acl" >/dev/null || fail "memory from 100G up must keep five characters: $(COLUMNS=200 "$top" | grep worker-1)"
"$job" heartbeat "$id" "worker=$(owner "$id")" load=0.10 mem=40 disk=61 cpus=4 vendor=DigitalOcean cpu_us=3700000 cpu_dt=1000000 rss=1840 peak=2100 build=5242880 phase=check
COLUMNS=200 "$top" | grep "  3.70  5.0G  1.8G  2.1G  check    arch     acl 1:2.3.2-1 | -" >/dev/null || fail "the phase the worker sent must show: $(COLUMNS=200 "$top" | grep worker-1)"
"$job" heartbeat "$id" "worker=$(owner "$id")" load=0.10 mem=40 disk=61 cpus=4 vendor=DigitalOcean cpu_us=3700000 cpu_dt=1000000 rss=1840 peak=2100 build=5242880
COLUMNS=200 "$top" | grep "  3.70  5.0G  1.8G  2.1G  -        arch     acl 1:2.3.2-1 | -" >/dev/null || fail "archci-top must show the job's cpu, memory and build size: $(COLUMNS=200 "$top" | grep worker-1)"

echo "--- a job's log is its entries in the workers' journal: a running job's so far, with a cursor to poll from"
# what the build's unit logged on the worker's host (worker-1: host "worker"), streamed to the master
journal_add worker "$(build_unit acl 1:2.3.2-1 x86_64 1)" "==> archci-build 0.5.0 $id on worker at 2026-09-15T10:00:00Z" "    repo=omarchy arch=x86_64" "==> Installing the pacman dependencies in the archci-online slice (with network) at 2026-09-15T10:00:05Z" "==> Building in the archci-offline slice (no network) at 2026-09-15T10:00:20Z" "building"
log=$("$master/archci-web" log "$id")
[[ $(jq -r '.lines | length' <<<"$log") == 5 && $(jq -r '.lines[0]' <<<"$log") == "==> archci-build 0.5.0 $id on worker at"* && $(jq -r '.state' <<<"$log") == running ]] || fail "archci web log of a running job is its journal so far: $log"
cursor=$(jq -r '.cursor' <<<"$log")
[[ $cursor == s=* ]] || fail "a running job's log comes with a cursor: $log"
[[ $(jq -r '.lines | length' <<<"$("$master/archci-web" log "$id" "$cursor")") == 0 && $(jq -r .cursor <<<"$("$master/archci-web" log "$id" "$cursor")") == "$cursor" ]] || fail "after the cursor, nothing new yet, and the poll keeps its cursor: $("$master/archci-web" log "$id" "$cursor")"
# the same log as entries, for a browser's log window: the line, when it was written, the slice markers; the cursor is the last entry's
ent=$("$master/archci-web" entries "$id")
[[ $(jq -r '.entries | length' <<<"$ent") == 5 && $(jq -r '.entries[0].MESSAGE' <<<"$ent") == "==> archci-build 0.5.0 $id on worker at"* && $(jq -r '.entries[0].__REALTIME_TIMESTAMP' <<<"$ent") == 1[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9] && $(jq -r '.entries[0].__CURSOR' <<<"$ent") == s=* && $(jq -r '.entries[0].__MONOTONIC_TIMESTAMP' <<<"$ent") == [0-9]* ]] || fail "archci web entries gives each line with its cursor and timestamps: $ent"
[[ $(jq -r '.entries[2].phase' <<<"$ent") == online && $(jq -r '.entries[3].phase' <<<"$ent") == offline && $(jq -r '.entries[4] | has("phase")' <<<"$ent") == false ]] || fail "entries carry the slice marker's phase: $ent"
[[ $(jq -r '.cursor' <<<"$ent") == "$cursor" && $(jq -r '.entries[-1].__CURSOR' <<<"$ent") == "$cursor" ]] || fail "the entries' cursor is the last entry's, the same as log's: $(jq -r .cursor <<<"$ent") vs $cursor"
[[ $(jq -c '[.entries, .cursor]' <<<"$("$master/archci-web" entries "$id" "$cursor")") == "[[],\"$cursor\"]" ]] || fail "entries after the cursor: nothing new yet, the cursor kept: $("$master/archci-web" entries "$id" "$cursor")"
journal_add worker "$(build_unit acl 1:2.3.2-1 x86_64 1)" "==> Starting build()..." "fields:ARCHCI_EVENT=finish|ARCHCI_RC=0|ARCHCI_JOB=$id||==> archci-build finished with 0 at 2026-09-15T10:01:43Z: acl-1:2.3.2-1-x86_64.pkg.tar.zst" "a stdout line the pipe held back, logged after the finish record"
[[ $(jq -r '.entries[0].MESSAGE' <<<"$("$master/archci-web" entries "$id" "$cursor")") == "==> Starting build()..." && $(jq -r '.entries[0].phase' <<<"$("$master/archci-web" entries "$id" "$cursor")") == build ]] || fail "entries after the cursor: only the new ones, makepkg's step as the phase: $("$master/archci-web" entries "$id" "$cursor")"
[[ $(jq -r '.entries[1].ARCHCI_EVENT + " " + .entries[1].ARCHCI_RC' <<<"$("$master/archci-web" entries "$id" "$cursor")") == "finish 0" ]] || fail "an archci record's fields come with the entry: $("$master/archci-web" entries "$id" "$cursor")"
[[ $(jq -r '.lines[0]' <<<"$("$master/archci-web" log "$id" "$cursor")") == "==> Starting build()..." ]] || fail "after the cursor, only the new lines: $("$master/archci-web" log "$id" "$cursor")"
journal_add worker "$(build_unit acl 1:2.3.2-1 x86_64 2)" "another attempt's line"   # not this attempt's
journal_add worker9 "$(build_unit acl 1:2.3.2-1 x86_64 1)" "the same unit on another host"   # not this worker's
[[ $(jq -r '.lines | length' <<<"$("$master/archci-web" log "$id")") == 8 ]] || fail "a job's log is its own unit's on its own host: $("$master/archci-web" log "$id")"

echo "--- report success pools packages and their builder signatures"
inc=$ARCHCI_HOME/incoming/$id
echo "log" >"$inc/build.log"   # an older worker's copy of the journal: dropped
pf=$(mkpkg "$inc" acl 1:2.3.2-1)
mkpkg "$inc" acl-debug 1:2.3.2-1 >/dev/null
: >"$pf.buildsig"   # carried through to the signer
pn=${pf##*/}
"$job" report "$id" success "$(owner "$id")"
[[ -f $ARCHCI_HOME/queue/done/$id.job ]] || fail "job not in done/"
grep -q '^load=0.10$' "$ARCHCI_HOME/queue/done/$id.job" || fail "a finished job must keep its last heartbeat stats"
grep -q '^heartbeat=20[0-9][0-9]-.*Z$' "$ARCHCI_HOME/queue/done/$id.job" || fail "a finished job must keep when its last heartbeat arrived"
"$top" | grep "^worker  *DigitalOcean  *x86_64  *0.10 .* 4  *2  *0  0.3.19-1$" >/dev/null || fail "archci-top must show an idle host with its last heartbeat, no active workers and the version its other worker sent: $("$top" | grep ^worker)"
# a worker not heard from for POLL_TTL is gone, however recent its last job
sed -i "s/^heartbeat=.*/heartbeat=$(date -u -d '-20 minutes' +%FT%TZ)/" "$ARCHCI_HOME/queue/done/$id.job"
"$top" | grep "^worker  *-  *x86_64  *0.20 .* 4  *1  *0  0.3.19-1$" >/dev/null || fail "a worker silent for 20 minutes must leave the hosts table even with a recent job; its host keeps the other worker: $("$top" | grep ^worker)"
sed -i "s/^heartbeat=.*/heartbeat=$(date -u +%FT%TZ)/" "$ARCHCI_HOME/queue/done/$id.job"
[[ $(<"$ARCHCI_HOME/built/omarchy-x86_64/acl") == "1:2.3.2-1 $(pkgcommit acl)" ]] || fail "built record wrong"
[[ -f $ARCHCI_HOME/repo/omarchy/os/x86_64/$pn ]] || fail "package not pooled under its hashed name: $(ls "$ARCHCI_HOME/repo/omarchy/os/x86_64")"
[[ -f $ARCHCI_HOME/repo/omarchy/os/x86_64/$pn.buildsig ]] || fail "buildsig not kept"
[[ -e $ARCHCI_HOME/publish.needed ]] || fail "publish flag missing"
[[ -z $(ls -A "$ARCHCI_HOME/logs") ]] || fail "the build log is the journal's, nothing is archived: $(find "$ARCHCI_HOME/logs")"
grep -q '^claimed=20' "$ARCHCI_HOME/queue/done/$id.job" || fail "a finished job keeps its claim time (it bounds its journal entries)"
grep -q '^last=a stdout line the pipe held back, logged after the finish record$' "$ARCHCI_HOME/queue/done/$id.job" || fail "the report keeps the log's last line in the job file: $(cat "$ARCHCI_HOME/queue/done/$id.job")"
grep -q '^error=' "$ARCHCI_HOME/queue/done/$id.job" && fail "no error line in a clean log"
log=$("$master/archci-web" log "$id")
[[ $(jq -r '.lines | length' <<<"$log") == 8 && $(jq -r '.cursor' <<<"$log") == null && $(jq -r '.error_at' <<<"$log") == null ]] || fail "a done job's log is read whole from the journal, no cursor: $log"
[[ $(jq -c '[(.entries | length), .cursor, .error_at, .state]' <<<"$("$master/archci-web" entries "$id")") == '[8,null,null,"done"]' ]] || fail "a done job's entries, whole, no cursor: $("$master/archci-web" entries "$id")"
echo "--- the log as server-sent events, live (archci web sse) and exported for R2 (archci web export), one framing"
sse=$("$master/archci-web" sse "$id")
[[ $sse == "event: job"$'\n'"data: {"* ]] || fail "the stream opens with the job event: ${sse:0:200}"
[[ $(grep -c '^id: s=' <<<"$sse") == 8 && $(grep -c '^data: {"time":"2026-' <<<"$sse") == 8 ]] || fail "one event per entry, its cursor as the id, its time in the data: $sse"
{ grep -q '"phase":"build"' <<<"$sse" && grep -q '"event":"finish"' <<<"$sse"; } || fail "the entries carry the phase and archci's event: $sse"
[[ $sse == *$'\n'"event: end"$'\n'"data: {\"state\":\"done\","*'"rc":0'* ]] || fail "a finished job's stream ends with the end event, its rc from the finish record: ${sse: -200}"
grep -q '"invocation":"feedfacefeedfacefeedfacefeedface"' <<<"$sse" || fail "the job event names the unit's invocation: ${sse:0:400}"
mkdir -p "$tmp/logs"
[[ $("$master/archci-web" export "$tmp/logs") == 1 ]] || fail "the finished job's log is exported once"
xf=$(find "$tmp/logs" -name '*.sse.zst'); [[ $xf == "$tmp/logs/omarchy/acl/1:2.3.2-1/x86_64/acl-1:2.3.2-1-x86_64-"[0-9]*"-feedfacefeedfacefeedfacefeedface.sse.zst" ]] || fail "the export is named by pkgbase, version, arch, the start and the invocation: $xf"
[[ $(zstd -dc "$xf") == "$sse" ]] || fail "the export is the same bytes as the live stream: $(diff <(echo "$sse") <(zstd -dc "$xf") | head -6)"
grep -q "^exported=${xf##*/}$" "$ARCHCI_HOME/queue/done/$id.job" || fail "the job file names its export: $(grep exported "$ARCHCI_HOME/queue/done/$id.job")"
[[ $("$master/archci-web" export "$tmp/logs") == 0 ]] || fail "not exported again"
# a log over ARCHCI_LOG_MAX_LINES keeps its first three quarters and its last quarter, a marker between
capped=$(ARCHCI_LOG_MAX_LINES=8 "$master/archci-web" sse "$id")
[[ $(grep -c '^id: s=' <<<"$capped") == 8 ]] || fail "8 entries fit the cap of 8 uncut: $(grep -c '^id: s=' <<<"$capped")"
capped=$(ARCHCI_LOG_MAX_LINES=7 "$master/archci-web" sse "$id")   # wait: the minimum is 8
[[ $(grep -c '^id: s=' <<<"$capped") == 8 ]] || fail "the cap is at least 8: $(grep -c '^id: s=' <<<"$capped")"
journal_add worker "$(build_unit acl 1:2.3.2-1 x86_64 1)" "extra line 1" "extra line 2" "extra line 3" "extra line 4"   # 12 entries now
capped=$(ARCHCI_LOG_MAX_LINES=8 "$master/archci-web" sse "$id")
[[ $(grep -c '^id: s=' <<<"$capped") == 8 && $(grep -c '^data: {"time":"2026-' <<<"$capped") == 9 ]] || fail "8 entries kept (6 + 2) and one marker without a cursor: $capped"
grep -q '"priority":"4","message":"... 4 line(s) not shown: the log has more than 8 lines (ARCHCI_LOG_MAX_LINES); the first 6 and the last 2 are"' <<<"$capped" || fail "the marker says what was cut: $(grep 'not shown' <<<"$capped")"
! grep -q '^id: *$' <<<"$capped" || fail "the marker has no id line at all (an empty one resets Last-Event-ID)"
[[ $(grep -o '"message":"extra line [0-9]"' <<<"$capped" | tr '\n' ' ') == '"message":"extra line 3" "message":"extra line 4" ' ]] || fail "the tail is the last quarter: $(grep -o '"message":"extra line [0-9]"' <<<"$capped")"
onejob=$("$master/archci-web" job "$id")
[[ $(jq -r '.started' <<<"$onejob") == 2026-09-15T10:00:00Z && $(jq -r '.stopped' <<<"$onejob") == 2026-09-15T10:01:43Z && $(jq -r '.online_at' <<<"$onejob") == 2026-09-15T10:00:05Z && $(jq -r '.build_at' <<<"$onejob") == 2026-09-15T10:00:20Z ]] || fail "the build's span and phases come from its journal entries: $onejob"
[[ $(jq -r '.log' <<<"$onejob") == "journalctl -D $ARCHCI_REMOTE_JOURNAL --no-pager -a -q -o json --since=@"*" --until=@"*" --output-fields=MESSAGE,PRIORITY,_PID,_SOURCE_REALTIME_TIMESTAMP,_SYSTEMD_INVOCATION_ID,ARCHCI_"*" _SYSTEMD_UNIT=$(build_unit acl 1:2.3.2-1 x86_64 1) _HOSTNAME=worker" ]] || fail "a job names its log as the journalctl the master runs for its entries: $(jq -r '.log' <<<"$onejob")"
[[ ! -e $inc ]] || fail "incoming not cleaned"
[[ $("$next") == "5 omarchy x86_64 libsigc++ "* ]] || fail "built package must not be outstanding"

echo "--- sources as src jobs: the sourcer claims them, hands in a source package, a build claim names it once staged"
[[ $("$next" src) == "5 omarchy src acl 1:2.3.2-1 $(pkgcommit acl) "* ]] || fail "archci-next src must offer the first package without a source package: $("$next" src)"
sid=$(claim_id sourcer src load=0.10 mem=5 disk=30 cpus=1 vendor=DigitalOcean archci=0.4.13-1)
[[ $sid == *omarchy,acl,1:2.3.2-1,src ]] || fail "the sourcer's claim must be a src job: $sid"
"$top" | grep "^sourcer  *DigitalOcean  *src  *0.10  *30  *5  *1  *1  *1  0.4.13-1$" >/dev/null || fail "archci-top must list the sourcer host as one worker, one job active: $("$top" | grep ^sourcer)"
inc=$ARCHCI_HOME/incoming/$sid
: >"$inc/acl-1:2.3.2-1.src.tar.gz"
"$job" report "$sid" success "$(owner "$sid")"
[[ -f $ARCHCI_HOME/queue/failed/$sid.job ]] || fail "a source package without its builder signature is refused"
"$job" retry "$sid" >/dev/null; sid=$(claim_id sourcer src); inc=$ARCHCI_HOME/incoming/$sid
journal_add sourcer archci-sourcer.service "==> archci-sourcer 0.5.0 $sid on sourcer at 2026-09-15T10:02:00Z" "fetched" "==> archci-sourcer finished with 0 at 2026-09-15T10:02:30Z"
: >"$inc/acl-1:2.3.2-1.src.tar.gz"; : >"$inc/acl-1:2.3.2-1.src.tar.gz.buildsig"
"$job" report "$sid" success "$(owner "$sid")"
# an unhashed upload (an older sourcer): named with its sha256 at ingest, the record names that
srec=$(<"$ARCHCI_HOME/built/omarchy-src/acl"); sf=${srec##* }
[[ $srec == "1:2.3.2-1 $(pkgcommit acl) acl-1:2.3.2-1-"*.src.tar.gz && $sf =~ ^acl-1:2\.3\.2-1-[0-9a-f]{64}\.src\.tar\.gz$ ]] || fail "the src built record must name the (hashed) file: $srec"
[[ -f $ARCHCI_HOME/repo/omarchy/os/src/$sf && -f $ARCHCI_HOME/repo/omarchy/os/src/$sf.buildsig && -e $ARCHCI_HOME/publish.needed ]] || fail "the source package and its buildsig must be pooled under os/src for archci-stage: $(ls "$ARCHCI_HOME/repo/omarchy/os/src")"
[[ $(jq -c '[.lines[1], (.lines | length)]' <<<"$("$master/archci-web" log "$sid")") == '["fetched",3]' ]] || fail "a fetch's log is the sourcer service's entries on its host: $("$master/archci-web" log "$sid")"
[[ $(jq -r '.started + " " + .stopped' <<<"$("$master/archci-web" job "$sid")") == "2026-09-15T10:02:00Z 2026-09-15T10:02:30Z" ]] || fail "a fetch's span comes from its journal entries: $("$master/archci-web" job "$sid")"
[[ $("$next" src) == "5 omarchy src libsigc++ "* ]] || fail "acl's sources are in; libsigc++ is next: $("$next" src)"
sid=$(claim_id sourcer src)
inc=$ARCHCI_HOME/incoming/$sid
# as the sourcer names it now: hashed, .src.tar.zst
echo sources | zstd -q >"$inc/libsigc++-2.12.2-1.src.tar.zst"; lsha=$(sha256sum "$inc/libsigc++-2.12.2-1.src.tar.zst" | cut -c1-64)
mv "$inc/libsigc++-2.12.2-1.src.tar.zst" "$inc/libsigc++-2.12.2-1-$lsha.src.tar.zst"; : >"$inc/libsigc++-2.12.2-1-$lsha.src.tar.zst.buildsig"
lsf=libsigc++-2.12.2-1-$lsha.src.tar.zst
"$job" report "$sid" success "$(owner "$sid")"
[[ $(<"$ARCHCI_HOME/built/omarchy-src/libsigc++") == "2.12.2-1 $(pkgcommit libsigc++) $lsf" && -f $ARCHCI_HOME/repo/omarchy/os/src/$lsf ]] || fail "a hashed .src.tar.zst is pooled as is: $(<"$ARCHCI_HOME/built/omarchy-src/libsigc++")"
sid=$(claim_id sourcer src)
[[ $sid == *omarchy,linux,* ]] || fail "linux's sources are next: $sid"
journal_add sourcer archci-sourcer.service "==> archci-sourcer 0.5.0 $sid on sourcer at 2026-09-15T10:03:00Z" "==> ERROR: Failure while downloading https://example/linux.tar.xz" "==> archci-sourcer finished with 1 at 2026-09-15T10:03:10Z"
"$job" report "$sid" failure "$(owner "$sid")"
grep -q '^error===> ERROR: Failure while downloading https://example/linux.tar.xz$' "$ARCHCI_HOME/queue/failed/$sid.job" || fail "the report keeps the log's first error line in the job file: $(cat "$ARCHCI_HOME/queue/failed/$sid.job")"
# the sourcer's previous fetch (acl's, seconds ago on the same host) is within this job's window: the log starts at this job's own header
[[ $(jq -c '[.error_at, (.entries | length), .entries[1].MESSAGE]' <<<"$("$master/archci-web" entries "$sid")") == '[1,3,"==> ERROR: Failure while downloading https://example/linux.tar.xz"]' ]] || fail "a failed job's entries are its own, from its header, and point at the first error: $("$master/archci-web" entries "$sid")"
[[ -f $ARCHCI_HOME/queue/failed/$sid.job ]] || fail "a failed fetch is a failed job"
[[ -z $("$next" src) ]] || fail "a failed src job is not offered again before its retry: $("$next" src)"
"$top" | grep "^sources: 2 packaged  1 to fetch  1 failed   (last fetch " >/dev/null || fail "top must show the sources' state: $("$top" | grep ^sources)"
"$top" | grep "^built: x86_64 1/3  any 0/0  src 2/3$" >/dev/null || fail "top must count the source packages beside the arches: $("$top" | grep ^built)"
"$failed" | grep "^linux 7.2.3.arch1-2 .* src  *arch  *sourcer  *1/2 retry .*: ==> ERROR: Failure while downloading" >/dev/null || fail "archci failed must list the fetch with its error: $("$failed" | grep ^linux)"
# a build waits for its source package while builds must not fetch
# upstream, and its claim names the package only once it has been out for
# the release lag (the signer has published it)
[[ -z $(ARCHCI_SOURCES_REQUIRED=1 ARCHCI_RELEASE_LAG_MINUTES=60 "$next" x86_64) ]] || fail "with sources required, a build whose source package is not released yet must wait: $(ARCHCI_SOURCES_REQUIRED=1 ARCHCI_RELEASE_LAG_MINUTES=60 "$next" x86_64)"
[[ $(ARCHCI_SOURCES_REQUIRED=1 "$next" x86_64) == "5 omarchy x86_64 libsigc++ "* ]] || fail "once released, the build is claimable: $(ARCHCI_SOURCES_REQUIRED=1 "$next" x86_64)"
id=$(ARCHCI_RELEASE_LAG_MINUTES=60 claim_id worker-2 x86_64)
grep -q '^sources=' "$ARCHCI_HOME/queue/running/$id.job" && fail "a claim must not name a source package the signer has not released yet"
"$job" report "$id" abandoned "$(owner "$id")"
# with archci-publish's listing of the release, the listing decides,
# not the lag (the abandoned job waits in pending/, so the claim is what
# shows it)
mkdir -p "$ARCHCI_HOME/released"; : >"$ARCHCI_HOME/released/omarchy-src"
id=$(claim_id worker-2 x86_64)
grep -q '^sources=' "$ARCHCI_HOME/queue/running/$id.job" && fail "a claim must not name a source package the listing lacks, whatever its age"
"$job" report "$id" abandoned "$(owner "$id")"
echo "$lsf" >"$ARCHCI_HOME/released/omarchy-src"
id=$(ARCHCI_RELEASE_LAG_MINUTES=60 claim_id worker-2 x86_64)
grep -qxF "sources=$lsf" "$ARCHCI_HOME/queue/running/$id.job" || fail "listed as released, the claim names the source package at once: $(cat "$ARCHCI_HOME/queue/running/$id.job")"
(( $(grep -c '^sources=' "$ARCHCI_HOME/queue/running/$id.job") == 1 )) || fail "a claim after a requeue must name the source package once, not once per claim: $(grep '^sources=' "$ARCHCI_HOME/queue/running/$id.job")"
"$job" report "$id" abandoned "$(owner "$id")"
rm -r "$ARCHCI_HOME/released"
"$job" enqueue linux 0 src >/dev/null
[[ $(claim_id sourcer src) == 0-*omarchy,linux,*,src ]] || fail "a package's sources can be enqueued by hand with ARCH=src"
# with sources required, a queued build waits in pending/ too until its source package is released
"$job" enqueue linux 0 x86_64 >/dev/null
held=$(ARCHCI_SOURCES_REQUIRED=1 claim_id worker-2 x86_64)   # libsigc++'s retry, whose source package is released, may come instead
[[ $held != *linux* ]] || fail "a queued build without a released source package must wait when sources are required: $held"
[[ -z $held ]] || "$job" report "$held" abandoned "$(owner "$held")"
[[ $(claim_id worker-2 x86_64) == 0-*omarchy,linux,*,x86_64 ]] || fail "without the requirement the queued build is claimed"
for f in "$ARCHCI_HOME"/queue/running/*linux*x86_64.job; do id=${f##*/}; "$job" report "${id%.job}" abandoned "$(owner "${id%.job}")"; done; rm -f "$ARCHCI_HOME"/queue/pending/*linux*x86_64.job
echo "--- the network exemption: package.json \"network\": true reaches the job"
mkpkgbuild netpkg 1-1 x86_64 '{"source": "arch", "network": true}'
commit_pkgs netpkg
"$scan" >/dev/null 2>&1
[[ $("$master/archci-pkgindex" netpkg | awk '{print $7}') == network ]] || fail "the index must flag the package: $("$master/archci-pkgindex" netpkg)"
"$job" enqueue netpkg 0 x86_64 >/dev/null
nid=$(claim_id worker-9 x86_64)
[[ $nid == *omarchy,netpkg,* ]] || fail "the enqueued job is claimed first: $nid"
grep -q '^network=full$' "$ARCHCI_HOME/queue/running/$nid.job" || fail "the job must carry network=full: $(cat "$ARCHCI_HOME/queue/running/$nid.job")"
"$job" report "$nid" failure "$(owner "$nid")" >/dev/null
grep -q '^network=full$' "$ARCHCI_HOME/queue/failed/$nid.job" || fail "a failure keeps the flag"
mkpkgbuild loopy 1-1 x86_64 '{"source": "arch", "network": "loopback"}'
commit_pkgs loopy; "$scan" >/dev/null 2>&1
[[ $("$master/archci-pkgindex" loopy | awk '{print $7}') == loopback ]] || fail "the index must know the loopback state: $("$master/archci-pkgindex" loopy)"
"$job" enqueue loopy 0 x86_64 >/dev/null
lid=$(claim_id worker-9 x86_64)
grep -q '^network=loopback$' "$ARCHCI_HOME/queue/running/$lid.job" || fail "the job must carry network=loopback: $(cat "$ARCHCI_HOME/queue/running/$lid.job")"
"$job" report "$lid" abandoned "$(owner "$lid")" >/dev/null; rm -rf "$ARCHCI_HOME"/queue/pending/*loopy* "$pkgs/pkgbuilds/loopy"
rm -rf "$ARCHCI_HOME"/queue/failed/*netpkg* "$pkgs/pkgbuilds/netpkg"; commit_pkgs "netpkg gone"; "$scan" >/dev/null 2>&1
echo "--- report failure, retry, give up"
"$master/archci-web" export "$tmp/logs" >/dev/null   # what earlier sections left exportable (the sourcer's failed fetch has its finish record)
id=$(claim_id worker-2 x86_64)
[[ $id == *omarchy,libsigc++,* ]] || fail "expected libsigc++ next, got $id"
grep -qxF "sources=$lsf" "$ARCHCI_HOME/queue/running/$id.job" || fail "the claim must name the source package: $(cat "$ARCHCI_HOME/queue/running/$id.job")"
journal_add worker "$(build_unit libsigc++ 2.12.2-1 x86_64 1)" "building" "stderr:==> ERROR: A failure occurred in build()."
"$job" report "$id" failure "$(owner "$id")"
[[ -f $ARCHCI_HOME/queue/failed/$id.job ]] || fail "not in failed/"
# its log has no finish record (killed hard): not exported until the settle time, then as it stands, the end event with the error
[[ $("$master/archci-web" export "$tmp/logs") == 0 ]] || fail "a log without its finish record waits"
[[ $("$master/archci-web" export "$tmp/logs" 0) == 1 ]] || fail "settled, it is exported as it stands"
xf=$(find "$tmp/logs" -path '*libsigc++*/x86_64/*' -name '*.sse.zst'); [[ $(zstd -dc "$xf" | tail -2 | head -1) == 'data: {"state":"failed","error_at":1,"finished":"20'* ]] || fail "the end event of a failed job: $(zstd -dc "$xf" 2>/dev/null | tail -2) / exported: $(find "$tmp/logs" -name "*.sse.zst")"
# a retry drops the export mark: the next attempt is a new log, exported afresh (the sourcer's failed linux fetch, exported above)
lsid=$(find "$ARCHCI_HOME/queue/failed" -name '*,linux,*,src.job' -printf '%f\n' | head -1); lsid=${lsid%.job}
grep -q '^exported=' "$ARCHCI_HOME/queue/failed/$lsid.job" || fail "the exported src job carries the mark: $(cat "$ARCHCI_HOME/queue/failed/$lsid.job")"
"$job" retry "$lsid" >/dev/null 2>&1
! grep -q '^exported=' "$ARCHCI_HOME/queue/pending/$lsid.job" || fail "a retry drops the export mark: $(cat "$ARCHCI_HOME/queue/pending/$lsid.job")"
"$failed" | grep "^libsigc++ 2.12.2-1 .* x86_64  *arch  *worker-2  *1/2 retry  *20.*: ==> ERROR: A failure occurred in build()" >/dev/null || fail "archci failed must list the failure with the first error line of its log: $("$failed")"
# a job file without the report's summary (from before it kept one): the listing reads the journal
sed -i '/^error=/d; /^last=/d' "$ARCHCI_HOME/queue/failed/$id.job"
"$failed" | grep "^libsigc++ 2.12.2-1 .*: ==> ERROR: A failure occurred in build()" >/dev/null || fail "without a summary in the job file, archci failed reads the journal: $("$failed")"
out=$("$master/archci-jobs")
grep -q "^libsigc++ 2.12.2-1 " <<<"$out" || fail "archci jobs must list the package as a tree root: $out"
grep -q "^  ._ x86_64  *failed  *worker-2  *1/2 .*: ==> ERROR: A failure occurred in build()" <<<"$out" || fail "archci jobs must list the failed job under it with its first error line: $out"
[[ $("$master/archci-jobs" failed libsigc | grep -c "_ ") == 1 && -z $("$master/archci-jobs" failed nosuchpkg) ]] || fail "archci jobs must filter by words: $("$master/archci-jobs" failed libsigc)"
listing=$("$master/archci-jobs" 'done' acl)
grep -q "^  ._ x86_64  *done  " <<<"$listing" || fail "archci jobs must list done jobs too: $("$master/archci-jobs" 'done' acl)"
snap=$("$master/archci-web" snapshot)
[[ $(jq -r '.jobs | length' <<<"$snap") == $(find "$ARCHCI_HOME"/queue -name "*.job" | wc -l) ]] || fail "archci web snapshot must list every job"
onejob=$("$master/archci-web" job "$id")
[[ $(jq -r '.id' <<<"$onejob") == "$id" && $(jq -r '.state' <<<"$onejob") == failed && $(jq -r '.repo' <<<"$onejob") == omarchy && $(jq -r '.generated' <<<"$onejob") == 20*Z ]] || fail "archci web job must return the one job with repo and generated: $onejob"
# this failed libsigc++ build named a source package; archci web job links the src job that made it
srcjob=$(jq -r '.sources_job' <<<"$onejob")
[[ $srcjob == *,libsigc++,2.12.2-1,src ]] || fail "archci web job must link the src job for a build with sources: $srcjob"
[[ -f $ARCHCI_HOME/queue/done/$srcjob.job || -f $ARCHCI_HOME/queue/running/$srcjob.job || -f $ARCHCI_HOME/queue/failed/$srcjob.job ]] || fail "the linked src job must exist: $srcjob"
! "$master/archci-web" job "9-1-x,nope,1-1,x86_64" 2>/dev/null || fail "archci web job of an unknown id must fail"
[[ $(jq -r --arg id "$id" '.jobs[] | select(.id == $id) | .story' <<<"$snap") == "failed "*" on worker-2, attempt 1 of 2; sources $lsf" ]] || fail "each job tells its story: $(jq -r --arg id "$id" '.jobs[] | select(.id == $id) | .story' <<<"$snap")"
[[ $(jq -r '.queue.failed' <<<"$snap") == $(find "$ARCHCI_HOME/queue/failed" -name "*.job" | wc -l) && $(jq -r '.generated' <<<"$snap") == 20*Z ]] || fail "the snapshot is archci top's plus jobs and generated: $(jq -c '[.queue, .generated]' <<<"$snap")"
log=$("$master/archci-web" log "$id")
[[ $(jq -r '.error_at' <<<"$log") == 1 && $(jq -r '.lines[1]' <<<"$log") == "==> ERROR: A failure occurred in build()." ]] || fail "archci web log gives the lines and the first error: $log"
[[ $(jq -c '[.entries[].PRIORITY]' <<<"$("$master/archci-web" entries "$id")") == '["6","3"]' ]] || fail "entries carry the journal priority (stdout 6, stderr 3): $("$master/archci-web" entries "$id")"
# the slice marker rule the entries' phase comes from: archci-build's transitions and nothing else
phases=$(ruby -e "require %q{$here/../lib/archci}; puts [
  '==> Installing the pacman dependencies in the archci-online slice (with network)', '==> Building in the archci-offline slice', '==> Building in the archci-online slice',
  '==> Building in the archci-loopback slice', '==> Building with the network: the package is exempt (package.json)', '==> Building with loopback: the package talks to itself (package.json)',
  '==> Installing missing dependencies...', '==> Starting build()...', '  Compiling starship v1.26.0'].map { |l| Archci.log_phase(l) || '-' }.join(' ')")
[[ $phases == "online offline online loopback online loopback - build -" ]] || fail "log_phase must mark archci-build's slice transitions and makepkg's steps, nothing else: $phases"
grep -q '^final=' "$ARCHCI_HOME/queue/failed/$id.job" && fail "should not be final yet"
"$housekeeping"
[[ -f $ARCHCI_HOME/queue/pending/$id.job ]] || fail "housekeeping should have requeued"
grep -q '^attempt=1$' "$ARCHCI_HOME/queue/pending/$id.job" || fail "attempt kept across requeue"
id2=$(claim_id worker-2 x86_64)
[[ $id2 == "$id" ]] || fail "retry should be claimed first (prio 5 vs linux prio 5, older ts)"
"$job" report "$id" failure "$(owner "$id")"
grep -q '^final=1$' "$ARCHCI_HOME/queue/failed/$id.job" || fail "should be final after max attempts"
"$housekeeping"
[[ -f $ARCHCI_HOME/queue/failed/$id.job ]] || fail "final job must stay failed"
[[ $("$next") == "5 omarchy x86_64 linux "* ]] || fail "a final failure at the same commit must be skipped"

echo "--- success reported with empty upload counts as failure"
id=$(claim_id worker-3 x86_64)
[[ $id == *linux* ]] || fail "expected linux, got $id"
"$job" report "$id" success "$(owner "$id")"
[[ -f $ARCHCI_HOME/queue/failed/$id.job ]] || fail "empty success must fail"

echo "--- stale running job is requeued by housekeeping; abandoned does not count"
"$job" retry "$id"
id=$(claim_id worker-4 x86_64)
touch -d '1 hour ago' "$ARCHCI_HOME/queue/running/$id.job"
"$housekeeping"
[[ -f $ARCHCI_HOME/queue/pending/$id.job ]] || fail "stale job not requeued"
id=$(claim_id worker-4 x86_64)
"$job" report "$id" abandoned "$(owner "$id")"
grep -q '^attempt=1$' "$ARCHCI_HOME/queue/pending/$id.job" || fail "abandoned must not count an attempt"

echo "--- a new commit of a package supersedes a pending job and a final failure"
mkpkgbuild linux 7.2.3.arch1-2 x86_64 '{"source": "arch", "note": "metadata only"}'   # same version, new commit
mkpkgbuild libsigc++ 2.12.3-1
commit_pkgs bump
"$scan"
"$housekeeping"
ls "$ARCHCI_HOME/queue/pending" | grep 'linux,7.2.3.arch1-2' >/dev/null && fail "superseded pending job not dropped"
[[ -z $(ls -A "$ARCHCI_HOME/queue/failed") ]] || fail "superseded final failure not dropped"
# a package removed from the repository takes its queued and failed jobs with it
mkpkgbuild gone 1-1; commit_pkgs gone; "$scan" >/dev/null 2>&1
"$job" enqueue gone 0 >/dev/null 2>&1
gid=$(claim_id worker-5 x86_64); [[ $gid == *omarchy,gone,* ]] || fail "the enqueued package is claimed: $gid"
"$job" report "$gid" failure "$(owner "$gid")" >/dev/null
"$job" enqueue gone 0 src >/dev/null 2>&1
"$housekeeping"
[[ $(ls "$ARCHCI_HOME"/queue/{pending,failed}/ | grep -c gone) == 2 ]] || fail "the jobs of a package still in the repository are kept (the failed one retried at once, ARCHCI_RETRY_MINUTES=0): $(ls "$ARCHCI_HOME"/queue/{pending,failed}/)"
rm -rf "$pkgs/pkgbuilds/gone"; commit_pkgs "gone gone"; "$scan" >/dev/null 2>&1
out=$("$housekeeping" 2>&1)
[[ $out == *"gone is gone from the PKGBUILD repository, dropping"* ]] || fail "housekeeping must say it drops the jobs of a removed package: $out"
! ls "$ARCHCI_HOME"/queue/{pending,failed}/ | grep -q gone || fail "the jobs of a package gone from the repository must be dropped: $(ls "$ARCHCI_HOME"/queue/{pending,failed}/)"
[[ $("$next") == "5 omarchy x86_64 libsigc++ 2.12.3-1 $(pkgcommit libsigc++) extra -" ]] || fail "new libsigc++ version should be next: $("$next")"
"$job" enqueue acl 0
ls "$ARCHCI_HOME/queue/pending" | grep '^0-.*omarchy,acl' >/dev/null || fail "manual enqueue"
! "$job" enqueue skipped 0 2>/dev/null || true   # skip_build packages may still be enqueued by hand
ls "$ARCHCI_HOME/queue/pending" | grep 'omarchy,skipped,1-1' >/dev/null || fail "manual enqueue of a skip_build package"
rm -f "$ARCHCI_HOME"/queue/pending/*skipped*
! "$job" enqueue nosuch 0 2>/dev/null || fail "enqueue of an unknown package must fail"

echo "--- a same-version commit does not rebuild a built package"
mkpkgbuild acl 1:2.3.2-1 x86_64 '{"source": "arch", "note": "metadata only"}'
commit_pkgs acl-metadata
"$scan"
[[ $("$next") != *" acl "* ]] || fail "acl was built at this version; a metadata commit must not rebuild it"

echo "--- top into a pipe prints one frame"
frame=$("$top")
[[ $frame == *"pkgbuilds -> [omarchy]   arches: x86_64"* ]] || fail "top title: $frame"
[[ $frame == *"queue: pending 1  running 0 "*"outstanding: 0 update(s), 2 unbuilt"* ]] || fail "top queue line: $frame"
[[ $frame == *"built: x86_64 1/3"* ]] || fail "top built line: $frame"

echo "--- a queued job the claim passes over is held: enqueue says so, top counts it, its story says why"
# the pending acl job was enqueued by hand; with a filter that excludes it, it waits (scan-test has the claim side)
ARCHCI_PKG_SOURCES=nothing "$job" enqueue acl 0 2>&1 | grep -q "note: acl is outside the farm's filter (ARCHCI_PKG_SOURCES=\"nothing\" ARCHCI_PKG_REPOS=\"\")" || fail "enqueue must say a job outside the filter waits: $(ARCHCI_PKG_SOURCES=nothing "$job" enqueue acl 0 2>&1)"
"$job" enqueue acl 0 2>&1 | grep -q "note:" && fail "enqueue of a package the farm builds must not warn: $("$job" enqueue acl 0 2>&1)"
frame=$(ARCHCI_PKG_SOURCES=nothing "$top")
[[ $frame == *"queue: pending 1 (1 held)  running 0 "* ]] || fail "top must count the held jobs beside pending: $frame"
# built and tracked count the packages the farm builds now: what was built before the filter is not counted past the total
[[ $frame == *"built: x86_64 0/0  any 0/0  src 0/0"* ]] || fail "top's built counts must follow the filter: $frame"
story=$(ARCHCI_PKG_SOURCES=nothing "$master/archci-web" snapshot | jq -r '.jobs[] | select(.state == "pending") | .story')
[[ $story == "pending since "*", attempt 1 of 2 next, held: outside the farm's filter" ]] || fail "a held job's story must say why: $story"
[[ $(ARCHCI_PKG_SOURCES=nothing "$master/archci-web" snapshot | jq -r '.queue.held') == 1 ]] || fail "the snapshot counts the held jobs"
[[ $("$master/archci-web" snapshot | jq -r '.queue.held') == 0 ]] || fail "without the filter nothing is held: $("$master/archci-web" snapshot | jq -c .queue)"
# with sources required, a queued build whose source package is not released yet is held too (linux: a new commit, its sources not fetched)
ARCHCI_SOURCES_REQUIRED=1 "$job" enqueue linux 0 x86_64 2>&1 | grep -q "note: the job waits in pending/ for the package's source package" || fail "enqueue must say a build waits for its source package"
story=$(ARCHCI_SOURCES_REQUIRED=1 "$master/archci-web" snapshot | jq -r '.jobs[] | select(.state == "pending" and .pkgbase == "linux") | .story')
[[ $story == *", held: waiting for its source package" ]] || fail "a build held for its source package says so: $story"
[[ $(ARCHCI_SOURCES_REQUIRED=1 "$master/archci-web" snapshot | jq -r '.queue.held') == 2 ]] || fail "the held count includes builds waiting for sources (linux, and acl whose sources were never fetched): $(ARCHCI_SOURCES_REQUIRED=1 "$master/archci-web" snapshot | jq -c '[.queue, [.jobs[] | select(.state == "pending") | .story]]')"
rm -f "$ARCHCI_HOME"/queue/pending/*linux*

echo "--- retry --all gives every failed job a fresh first attempt"
# two jobs that gave up (final after max attempts), as report leaves them
failed_ids=()
for p in acl:1:2.3.2-1 libsigc++:3.6.0-1; do
	fid="5-1700000000-omarchy,${p%%:*},${p#*:},x86_64.job"
	printf 'id=%s\nrepo=omarchy\narch=x86_64\npkgbase=%s\nversion=%s\ncommit=%s\nprofile=extra\ncreated=2026-01-01T00:00:00Z\nattempt=3\nworker=worker-1\nstatus=failure\nfinished=2026-01-01T01:00:00Z\nfinal=1\n' \
		"${fid%.job}" "${p%%:*}" "${p#*:}" "$(pkgcommit "${p%%:*}")" >"$ARCHCI_HOME/queue/failed/$fid"
	failed_ids+=("$fid")
done
"$job" retry --all
[[ -z $(ls -A "$ARCHCI_HOME/queue/failed") ]] || fail "retry --all must empty failed/"
for f in "${failed_ids[@]}"; do
	[[ -f $ARCHCI_HOME/queue/pending/$f ]] || fail "$f not requeued by retry --all"
	grep -q '^attempt=0$' "$ARCHCI_HOME/queue/pending/$f" || fail "attempt not reset in $f"
	grep -q '^final=' "$ARCHCI_HOME/queue/pending/$f" && fail "final flag kept in $f"
done
! "$job" retry 2>/dev/null || fail "retry needs a job id or --all"
"$job" retry -a   # nothing failed: fine, retries 0

echo "--- a claim carries the host's stats; an idle worker's host still shows"
# a riscv64 poll: the pending x86_64 jobs are not its to take, and with no
# package source enabled nothing is outstanding, so it gets no job
ARCHCI_ARCHES="x86_64 riscv64" ARCHCI_PKG_SOURCES=nothing "$job" claim idle-host-1 riscv64 load=0.50 mem=10 disk=20 cpus=2 vendor=DigitalOcean archci=0.3.19-1 | grep . >/dev/null && fail "an idle poll must get no job here"
grep -q '^vendor=DigitalOcean$' "$ARCHCI_HOME/hosts/idle-host-1" || fail "the claim's host stats must be kept in hosts/"
grep -q '^seen=20' "$ARCHCI_HOME/hosts/idle-host-1" || fail "hosts/ entry must say when the worker polled"
"$top" | grep "^idle-host  *DigitalOcean  *riscv64  *0.50  *20  *10  *2  *1  *0  0.3.19-1$" >/dev/null || fail "archci-top must show an idle host from its poll, with the archci it runs: $("$top" | grep idle-host)"
# shellcheck disable=SC2016  # a literal shell-looking stat, meant to be rejected
! ARCHCI_ARCHES="x86_64 riscv64" "$job" claim idle-host-1 riscv64 'load=$(true)' 2>/dev/null || fail "a malformed host stat must be refused"
touch -d '20 minutes ago' "$ARCHCI_HOME/hosts/idle-host-1"; sed -i "s/^seen=.*/seen=$(date -u -d '20 minutes ago' +%FT%TZ)/" "$ARCHCI_HOME/hosts/idle-host-1"
# the sourcer's idle claim (arch src) keeps its host in the table with no
# worker, ahead of the workers; a malformed stat is refused
out=$("$job" claim srcr src load=0.10 mem=5 disk=30 cpus=1 vendor=DigitalOcean archci=0.4.13-1)
[[ -z $out ]] || "$job" report "$(sed -n 's/^id=//p' <<<"$out")" abandoned srcr   # handed back: the host is idle again
"$top" | grep "^srcr  *DigitalOcean  *src  *0.10  *30  *5  *1  *1  *0  0.4.13-1$" >/dev/null || fail "archci-top must list the idle sourcer host as one worker: $("$top" | grep ^srcr)"
order=$("$top" | sed -n '/^HOST/,/^$/p' | awk '/^srcr |^sourcer |^idle-host |^worker /{printf "%s ", $1}')
[[ $order == "sourcer srcr worker " ]] || fail "the sourcers must come before the workers in the hosts table: $order"
# shellcheck disable=SC2016  # a literal shell-looking stat, meant to be rejected
! "$job" claim srcr src 'load=$(true)' 2>/dev/null || fail "a malformed host stat must be refused"
"$top" | grep "^idle-host " >/dev/null && fail "a worker that stopped polling must drop out of the hosts table"
"$housekeeping"
[[ -f $ARCHCI_HOME/hosts/idle-host-1 ]] || fail "housekeeping must keep a poll younger than a day"
touch -d '2 days ago' "$ARCHCI_HOME/hosts/idle-host-1"
"$housekeeping"
[[ ! -e $ARCHCI_HOME/hosts/idle-host-1 ]] || fail "housekeeping must drop a poll older than a day"

echo "--- a report or heartbeat from a worker the job was taken from is refused"
tid=$(claim_id taken-1 x86_64)
[[ -n $tid ]] || fail "taken-1 should have got a job"
"$job" retry "$tid" >/dev/null                      # requeued while taken-1 still builds it
[[ $(claim_id taker-1 x86_64) == "$tid" ]] || fail "the retried job goes to the next claim"
! "$job" heartbeat "$tid" worker=taken-1 load=1 2>/dev/null || fail "the old worker's heartbeat must be refused"
! "$job" report "$tid" failure taken-1 2>/dev/null || fail "the old worker's report must be refused"
! "$job" heartbeat "$tid" load=1 2>/dev/null || fail "a heartbeat that names no worker must be refused"
! "$job" report "$tid" failure 2>/dev/null || fail "a report that names no worker must be refused"
[[ -f $ARCHCI_HOME/queue/running/$tid.job ]] || fail "the job must still be running for its new worker"
"$job" heartbeat "$tid" worker=taker-1 load=1 || fail "the new worker's heartbeat is taken"
"$job" report "$tid" abandoned taker-1 || fail "the new worker's report is taken"
[[ -f $ARCHCI_HOME/queue/pending/$tid.job ]] || fail "abandoned by its worker: back in pending/"
rm -f "$ARCHCI_HOME/queue/pending/$tid.job"
echo "--- a claim from a worker whose job is still running hands that job back"
id=$(claim_id dup-1 x86_64)
[[ -n $id ]] || fail "dup-1 should have got a pending job"
out=$("$job" claim dup-1 x86_64 2>&1)   # captured: grep -q on a pipe would SIGPIPE the writer
grep -q "still running for dup-1, which asks for new work; requeued" <<<"$out" || fail "the second claim must hand the running job back first: $out"
(( $(grep -l '^worker=dup-1$' "$ARCHCI_HOME"/queue/running/*.job | wc -l) == 1 )) || fail "dup-1 must hold exactly one running job"
# the job handed back is first in pending, so the same worker gets it again: attempt 1, not 2
grep -q '^attempt=1$' "$ARCHCI_HOME/queue/running/$id.job" || fail "the orphaned attempt must not count: $(grep ^attempt= "$ARCHCI_HOME/queue/running/$id.job")"
echo "--- a failed job's retry waits for a dependency this repository has yet to build"
mkpkgbuild lib 1-1
mkpkgbuild app 1-1
sed -i 's/^arch=/depends=(lib)\narch=/' "$pkgs/pkgbuilds/app/PKGBUILD"
commit_pkgs app-and-lib
"$scan"
[[ $("$next" --waiting app x86_64) == lib ]] || fail "archci-next --waiting must name the unbuilt dependency: $("$next" --waiting app x86_64)"
[[ -z $("$next" --waiting lib x86_64) ]] || fail "archci-next --waiting must be empty for a package with its dependencies built"
printf 'id=5-1-omarchy,app,1-1,x86_64\nrepo=omarchy\narch=x86_64\npkgbase=app\nversion=1-1\ncommit=%s\nprofile=extra\ncreated=2026-01-01T00:00:00Z\nattempt=1\nworker=w\nstatus=failure\nfinished=2026-01-01T01:00:00Z\n' "$(pkgcommit app)" >"$ARCHCI_HOME/queue/failed/5-1-omarchy,app,1-1,x86_64.job"
"$housekeeping"
[[ -f $ARCHCI_HOME/queue/failed/5-1-omarchy,app,1-1,x86_64.job ]] || fail "a retry must be held while its dependency is unbuilt"
ARCHCI_RETRY_HOLD_MINUTES=0 "$housekeeping"
[[ -f $ARCHCI_HOME/queue/pending/5-1-omarchy,app,1-1,x86_64.job ]] || fail "the hold must end after ARCHCI_RETRY_HOLD_MINUTES"
mv "$ARCHCI_HOME/queue/pending/5-1-omarchy,app,1-1,x86_64.job" "$ARCHCI_HOME/queue/failed/"
mkdir -p "$ARCHCI_HOME/built/omarchy-x86_64"; echo "1-1 $(pkgcommit lib)" >"$ARCHCI_HOME/built/omarchy-x86_64/lib"
"$housekeeping"
[[ -f $ARCHCI_HOME/queue/pending/5-1-omarchy,app,1-1,x86_64.job ]] || fail "a retry must go ahead once its dependency is built"
echo "ALL OK"
