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
"$job" heartbeat "$id"
"$job" heartbeat "$id" load=1.50 mem=42 disk=61 cpus=4
grep -q '^load=1.50$' "$ARCHCI_HOME/queue/running/$id.job" || fail "heartbeat stats not kept with the job"
"$job" heartbeat "$id" load=0.10 mem=40 disk=61 cpus=4 vendor=DigitalOcean cpu_us=3700000 cpu_dt=1000000 rss=1840 peak=2100 build=5242880
grep -q '^build=5242880$' "$ARCHCI_HOME/queue/running/$id.job" || fail "job stats not kept"
(( $(grep -c '^load=' "$ARCHCI_HOME/queue/running/$id.job") == 1 )) || fail "heartbeat stats must be replaced, not appended"
# shellcheck disable=SC2016  # a literal shell-looking stat, meant to be rejected
! "$job" heartbeat "$id" 'load=$(rm -rf /)' 2>/dev/null || fail "a malformed stat must be refused"
! "$job" heartbeat "9-1-omarchy,nope,1-1,x86_64" 2>/dev/null || fail "heartbeat of unknown job must fail"
me=$(cut -d. -f1 /proc/sys/kernel/hostname)
"$top" | sed -n '/^HOST/{n;p}' | grep "^$me .*  -  *-  " >/dev/null || fail "the master itself must be the first host row, with - for workers and active: $("$top" | sed -n '/^HOST/{n;p}')"
"$top" | grep "^worker  *DigitalOcean  *x86_64  *0.10 .* 4  *1  *1  -$" >/dev/null || fail "archci-top must show the host's arch, vendor, stats, threads, worker count, active workers and a dash for an unknown archci version: $("$top" | grep ^worker)"
# a second worker of the host says which archci it runs; a newer beat from
# the first, which says nothing, must not hide that
ARCHCI_PKG_SOURCES=nothing "$job" claim worker-2 x86_64 load=0.20 mem=40 disk=61 cpus=4 archci=0.3.19-1 | grep . >/dev/null && fail "worker-2's poll must get no job with no sources enabled"
"$job" heartbeat "$id" load=0.10 mem=40 disk=61 cpus=4 vendor=DigitalOcean cpu_us=3700000 cpu_dt=1000000 rss=1840 peak=2100 build=5242880
"$top" | grep "^worker  *DigitalOcean  *x86_64  *0.10 .* 4  *2  *1  0.3.19-1$" >/dev/null || fail "the archci version must come from whichever worker sent it: $("$top" | grep ^worker)"
printf '{"generated":"2026-01-01T00:00:00Z","staging":{"waiting":2,"oldest_s":90},"release":{"x86_64":{"updated":"2026-01-01T00:00:00Z","packages":63},"aarch64":{"updated":null,"packages":null}}}\n' >"$ARCHCI_HOME/signer.status"
"$top" | grep "^unsigned: 2 pkg in staging (oldest 1m30s)$" >/dev/null || fail "archci-top must show the unsigned staging backlog from signer.status: $("$top" | grep ^unsigned)"
"$top" | grep "^released: x86_64 63 pkg  aarch64 unreachable$" >/dev/null || fail "the released line must show the released databases per arch: $("$top" | grep ^released)"
"$job" heartbeat "$id" load=0.10 mem=40 disk=61 cpus=4 vendor=DigitalOcean cpu_us=3700000 cpu_dt=1000000 rss=104858 peak=204800 build=134217728
COLUMNS=200 "$top" | grep "  3.70  128G  102G  200G  -        arch     acl" >/dev/null || fail "memory from 100G up must keep five characters: $(COLUMNS=200 "$top" | grep worker-1)"
"$job" heartbeat "$id" load=0.10 mem=40 disk=61 cpus=4 vendor=DigitalOcean cpu_us=3700000 cpu_dt=1000000 rss=1840 peak=2100 build=5242880 phase=check
COLUMNS=200 "$top" | grep "  3.70  5.0G  1.8G  2.1G  check    arch     acl 1:2.3.2-1 | -" >/dev/null || fail "the phase the worker sent must show: $(COLUMNS=200 "$top" | grep worker-1)"
"$job" heartbeat "$id" load=0.10 mem=40 disk=61 cpus=4 vendor=DigitalOcean cpu_us=3700000 cpu_dt=1000000 rss=1840 peak=2100 build=5242880
COLUMNS=200 "$top" | grep "  3.70  5.0G  1.8G  2.1G  -        arch     acl 1:2.3.2-1 | -" >/dev/null || fail "archci-top must show the job's cpu, memory and build size: $(COLUMNS=200 "$top" | grep worker-1)"

echo "--- report success pools packages and their builder signatures"
inc=$ARCHCI_HOME/incoming/$id
echo "log" >"$inc/build.log"
mkpkg "$inc" acl 1:2.3.2-1
mkpkg "$inc" acl-debug 1:2.3.2-1
: >"$inc/acl-1:2.3.2-1-x86_64.pkg.tar.zst.buildsig"   # carried through to the signer
"$job" report "$id" success
[[ -f $ARCHCI_HOME/queue/done/$id.job ]] || fail "job not in done/"
grep -q '^load=0.10$' "$ARCHCI_HOME/queue/done/$id.job" || fail "a finished job must keep its last heartbeat stats"
grep -q '^heartbeat=20[0-9][0-9]-.*Z$' "$ARCHCI_HOME/queue/done/$id.job" || fail "a finished job must keep when its last heartbeat arrived"
"$top" | grep "^worker  *DigitalOcean  *x86_64  *0.10 .* 4  *2  *0  0.3.19-1$" >/dev/null || fail "archci-top must show an idle host with its last heartbeat, no active workers and the version its other worker sent: $("$top" | grep ^worker)"
# a worker not heard from for POLL_TTL is gone, however recent its last job
sed -i "s/^heartbeat=.*/heartbeat=$(date -u -d '-20 minutes' +%FT%TZ)/" "$ARCHCI_HOME/queue/done/$id.job"
"$top" | grep "^worker  *-  *x86_64  *0.20 .* 4  *1  *0  0.3.19-1$" >/dev/null || fail "a worker silent for 20 minutes must leave the hosts table even with a recent job; its host keeps the other worker: $("$top" | grep ^worker)"
sed -i "s/^heartbeat=.*/heartbeat=$(date -u +%FT%TZ)/" "$ARCHCI_HOME/queue/done/$id.job"
[[ $(<"$ARCHCI_HOME/built/omarchy-x86_64/acl") == "1:2.3.2-1 $(pkgcommit acl)" ]] || fail "built record wrong"
[[ -f $ARCHCI_HOME/repo/omarchy/os/x86_64/acl-1:2.3.2-1-x86_64.pkg.tar.zst ]] || fail "package not pooled"
[[ -f $ARCHCI_HOME/repo/omarchy/os/x86_64/acl-1:2.3.2-1-x86_64.pkg.tar.zst.buildsig ]] || fail "buildsig not kept"
[[ -e $ARCHCI_HOME/stage.needed ]] || fail "stage flag missing"
[[ -f $ARCHCI_HOME/logs/omarchy/acl/1:2.3.2-1/x86_64/attempt-1.log ]] || fail "log not archived"
[[ ! -e $inc ]] || fail "incoming not cleaned"
[[ $("$next") == "5 omarchy x86_64 libsigc++ "* ]] || fail "built package must not be outstanding"

echo "--- sources as src jobs: the sourcer claims them, hands in a source package, a build claim names it once staged"
[[ $("$next" src) == "5 omarchy src acl 1:2.3.2-1 $(pkgcommit acl) "* ]] || fail "archci-next src must offer the first package without a source package: $("$next" src)"
sid=$(claim_id sourcer src load=0.10 mem=5 disk=30 cpus=1 vendor=DigitalOcean archci=0.4.13-1)
[[ $sid == *omarchy,acl,1:2.3.2-1,src ]] || fail "the sourcer's claim must be a src job: $sid"
"$top" | grep "^sourcer  *DigitalOcean  *src  *0.10  *30  *5  *1  *1  *1  0.4.13-1$" >/dev/null || fail "archci-top must list the sourcer host as one worker, one job active: $("$top" | grep ^sourcer)"
inc=$ARCHCI_HOME/incoming/$sid
echo fetched >"$inc/build.log"; : >"$inc/acl-1:2.3.2-1.src.tar.gz"
"$job" report "$sid" success
[[ -f $ARCHCI_HOME/queue/failed/$sid.job ]] || fail "a source package without its builder signature is refused"
"$job" retry "$sid" >/dev/null; sid=$(claim_id sourcer src); inc=$ARCHCI_HOME/incoming/$sid
echo fetched >"$inc/build.log"; : >"$inc/acl-1:2.3.2-1.src.tar.gz"; : >"$inc/acl-1:2.3.2-1.src.tar.gz.buildsig"
"$job" report "$sid" success
[[ $(<"$ARCHCI_HOME/built/omarchy-src/acl") == "1:2.3.2-1 $(pkgcommit acl) acl-1:2.3.2-1.src.tar.gz" ]] || fail "the src built record must name the file: $(<"$ARCHCI_HOME/built/omarchy-src/acl")"
[[ -f $ARCHCI_HOME/repo/omarchy/os/src/acl-1:2.3.2-1.src.tar.gz && -f $ARCHCI_HOME/repo/omarchy/os/src/acl-1:2.3.2-1.src.tar.gz.buildsig && -e $ARCHCI_HOME/stage.needed ]] || fail "the source package and its buildsig must be pooled under os/src for archci-stage"
[[ -f $ARCHCI_HOME/logs/omarchy/acl/1:2.3.2-1/src/attempt-1.log ]] || fail "the fetch's log must be archived under the src arch"
[[ $("$next" src) == "5 omarchy src libsigc++ "* ]] || fail "acl's sources are in; libsigc++ is next: $("$next" src)"
sid=$(claim_id sourcer src)
inc=$ARCHCI_HOME/incoming/$sid
echo fetched >"$inc/build.log"; : >"$inc/libsigc++-2.12.2-1.src.tar.gz"; : >"$inc/libsigc++-2.12.2-1.src.tar.gz.buildsig"
"$job" report "$sid" success
sid=$(claim_id sourcer src)
[[ $sid == *omarchy,linux,* ]] || fail "linux's sources are next: $sid"
echo "==> ERROR: Failure while downloading https://example/linux.tar.xz" >"$ARCHCI_HOME/incoming/$sid/build.log"
"$job" report "$sid" failure
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
"$job" report "$id" abandoned
# with archci-signer-status' listing of the release, the listing decides,
# not the lag (the abandoned job waits in pending/, so the claim is what
# shows it)
mkdir -p "$ARCHCI_HOME/released"; : >"$ARCHCI_HOME/released/omarchy-src"
id=$(claim_id worker-2 x86_64)
grep -q '^sources=' "$ARCHCI_HOME/queue/running/$id.job" && fail "a claim must not name a source package the listing lacks, whatever its age"
"$job" report "$id" abandoned
echo libsigc++-2.12.2-1.src.tar.gz >"$ARCHCI_HOME/released/omarchy-src"
id=$(ARCHCI_RELEASE_LAG_MINUTES=60 claim_id worker-2 x86_64)
grep -q '^sources=libsigc++-2.12.2-1.src.tar.gz$' "$ARCHCI_HOME/queue/running/$id.job" || fail "listed as released, the claim names the source package at once: $(cat "$ARCHCI_HOME/queue/running/$id.job")"
(( $(grep -c '^sources=' "$ARCHCI_HOME/queue/running/$id.job") == 1 )) || fail "a claim after a requeue must name the source package once, not once per claim: $(grep '^sources=' "$ARCHCI_HOME/queue/running/$id.job")"
"$job" report "$id" abandoned
rm -r "$ARCHCI_HOME/released"
"$job" enqueue linux 0 src >/dev/null
[[ $(claim_id sourcer src) == 0-*omarchy,linux,*,src ]] || fail "a package's sources can be enqueued by hand with ARCH=src"
echo "--- the network exemption: package.json \"network\": true reaches the job"
mkpkgbuild netpkg 1-1 x86_64 '{"source": "arch", "network": true}'
commit_pkgs netpkg
"$scan" >/dev/null 2>&1
[[ $("$master/archci-pkgindex" netpkg | awk '{print $7}') == network ]] || fail "the index must flag the package: $("$master/archci-pkgindex" netpkg)"
"$job" enqueue netpkg 0 x86_64 >/dev/null
nid=$(claim_id worker-9 x86_64)
[[ $nid == *omarchy,netpkg,* ]] || fail "the enqueued job is claimed first: $nid"
grep -q '^network=1$' "$ARCHCI_HOME/queue/running/$nid.job" || fail "the job must carry network=1: $(cat "$ARCHCI_HOME/queue/running/$nid.job")"
"$job" report "$nid" failure >/dev/null
grep -q '^network=1$' "$ARCHCI_HOME/queue/failed/$nid.job" || fail "a failure keeps the flag"
rm -rf "$ARCHCI_HOME"/queue/failed/*netpkg* "$pkgs/pkgbuilds/netpkg"; commit_pkgs "netpkg gone"; "$scan" >/dev/null 2>&1
echo "--- report failure, retry, give up"
id=$(claim_id worker-2 x86_64)
[[ $id == *omarchy,libsigc++,* ]] || fail "expected libsigc++ next, got $id"
grep -q '^sources=libsigc++-2.12.2-1.src.tar.gz$' "$ARCHCI_HOME/queue/running/$id.job" || fail "the claim must name the source package: $(cat "$ARCHCI_HOME/queue/running/$id.job")"
"$job" report "$id" failure
[[ -f $ARCHCI_HOME/queue/failed/$id.job ]] || fail "not in failed/"
mkdir -p "$ARCHCI_HOME/logs/omarchy/libsigc++/2.12.2-1/x86_64"
printf 'building\n==> ERROR: A failure occurred in build().\n' >"$ARCHCI_HOME/logs/omarchy/libsigc++/2.12.2-1/x86_64/attempt-1.log"
"$failed" | grep "^libsigc++ 2.12.2-1 .* x86_64  *arch  *worker-2  *1/2 retry  *20.*: ==> ERROR: A failure occurred in build()" >/dev/null || fail "archci failed must list the failure with the first error line of its log: $("$failed")"
out=$("$master/archci-jobs")
grep -q "^libsigc++ 2.12.2-1 " <<<"$out" || fail "archci jobs must list the package as a tree root: $out"
grep -q "^  ._ x86_64  *failed  *worker-2  *1/2 .*: ==> ERROR: A failure occurred in build()" <<<"$out" || fail "archci jobs must list the failed job under it with its first error line: $out"
[[ $("$master/archci-jobs" failed libsigc | grep -c "_ ") == 1 && -z $("$master/archci-jobs" failed nosuchpkg) ]] || fail "archci jobs must filter by words: $("$master/archci-jobs" failed libsigc)"
"$master/archci-jobs" 'done' acl | grep -q "^  ._ x86_64  *done  " || fail "archci jobs must list done jobs too: $("$master/archci-jobs" 'done' acl)"
grep -q '^final=' "$ARCHCI_HOME/queue/failed/$id.job" && fail "should not be final yet"
"$housekeeping"
[[ -f $ARCHCI_HOME/queue/pending/$id.job ]] || fail "housekeeping should have requeued"
grep -q '^attempt=1$' "$ARCHCI_HOME/queue/pending/$id.job" || fail "attempt kept across requeue"
id2=$(claim_id worker-2 x86_64)
[[ $id2 == "$id" ]] || fail "retry should be claimed first (prio 5 vs linux prio 5, older ts)"
"$job" report "$id" failure
grep -q '^final=1$' "$ARCHCI_HOME/queue/failed/$id.job" || fail "should be final after max attempts"
"$housekeeping"
[[ -f $ARCHCI_HOME/queue/failed/$id.job ]] || fail "final job must stay failed"
[[ $("$next") == "5 omarchy x86_64 linux "* ]] || fail "a final failure at the same commit must be skipped"

echo "--- success reported with empty upload counts as failure"
id=$(claim_id worker-3 x86_64)
[[ $id == *linux* ]] || fail "expected linux, got $id"
"$job" report "$id" success
[[ -f $ARCHCI_HOME/queue/failed/$id.job ]] || fail "empty success must fail"

echo "--- stale running job is requeued by housekeeping; abandoned does not count"
"$job" retry "$id"
id=$(claim_id worker-4 x86_64)
touch -d '1 hour ago' "$ARCHCI_HOME/queue/running/$id.job"
"$housekeeping"
[[ -f $ARCHCI_HOME/queue/pending/$id.job ]] || fail "stale job not requeued"
id=$(claim_id worker-4 x86_64)
"$job" report "$id" abandoned
grep -q '^attempt=1$' "$ARCHCI_HOME/queue/pending/$id.job" || fail "abandoned must not count an attempt"

echo "--- a new commit of a package supersedes a pending job and a final failure"
mkpkgbuild linux 7.2.3.arch1-2 x86_64 '{"source": "arch", "note": "metadata only"}'   # same version, new commit
mkpkgbuild libsigc++ 2.12.3-1
commit_pkgs bump
"$scan"
"$housekeeping"
ls "$ARCHCI_HOME/queue/pending" | grep 'linux,7.2.3.arch1-2' >/dev/null && fail "superseded pending job not dropped"
[[ -z $(ls -A "$ARCHCI_HOME/queue/failed") ]] || fail "superseded final failure not dropped"
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
[[ $frame == *"queue: pending 1 "*"outstanding: 0 update(s), 2 unbuilt"* ]] || fail "top queue line: $frame"
[[ $frame == *"built: x86_64 1/3"* ]] || fail "top built line: $frame"

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
[[ -z $out ]] || "$job" report "$(sed -n 's/^id=//p' <<<"$out")" abandoned   # handed back: the host is idle again
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
