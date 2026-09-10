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
"$job" heartbeat "$id" load=0.10 mem=40 disk=61 cpus=4 vendor=DigitalOcean cpu=3.7 rss=1840 peak=2100 build=5.0G
grep -q '^build=5.0G$' "$ARCHCI_HOME/queue/running/$id.job" || fail "job stats not kept"
(( $(grep -c '^load=' "$ARCHCI_HOME/queue/running/$id.job") == 1 )) || fail "heartbeat stats must be replaced, not appended"
# shellcheck disable=SC2016  # a literal shell-looking stat, meant to be rejected
! "$job" heartbeat "$id" 'load=$(rm -rf /)' 2>/dev/null || fail "a malformed stat must be refused"
! "$job" heartbeat "9-1-omarchy,nope,1-1,x86_64" 2>/dev/null || fail "heartbeat of unknown job must fail"
me=$(cut -d. -f1 /proc/sys/kernel/hostname)
"$top" --once --no-journal | sed -n '/^HOST/{n;p}' | grep "^$me .*  0  *0  " >/dev/null || fail "the master itself must be the first host row, with no workers: $("$top" --once --no-journal | sed -n '/^HOST/{n;p}')"
"$top" --once --no-journal | grep "^worker  *DigitalOcean  *x86_64  *0.10 .* 4  *1  *1  -$" >/dev/null || fail "archci-top must show the host's arch, vendor, stats, threads, worker count, active workers and a dash for an unknown archci version: $("$top" --once --no-journal | grep ^worker)"
printf '{"generated":"2026-01-01T00:00:00Z","staging":{"waiting":2,"oldest_s":90},"release":{"x86_64":{"updated":"2026-01-01T00:00:00Z","packages":63},"aarch64":{"updated":null,"packages":null}}}\n' >"$ARCHCI_HOME/signer.status"
"$top" --once --no-journal | grep "^signer: staging 2 pkg (oldest 1m30s)   release x86_64 63 pkg  aarch64 unreachable" >/dev/null || fail "archci-top must show the signer status from signer.status"
COLUMNS=200 "$top" --once --no-journal | grep "  370  5.0G  1.8G  2.1G  -        arch     acl 1:2.3.2-1 | -" >/dev/null || fail "archci-top must show the job's cpu, memory and build size: $(COLUMNS=200 "$top" --once --no-journal | grep worker-1)"

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
"$top" --once --no-journal | grep "^worker  *DigitalOcean  *x86_64  *0.10 .* 4  *1  *0  -$" >/dev/null || fail "archci-top must show an idle host with its last heartbeat and no active workers"
[[ $(<"$ARCHCI_HOME/built/omarchy-x86_64/acl") == "1:2.3.2-1 $(pkgcommit acl)" ]] || fail "built record wrong"
[[ -f $ARCHCI_HOME/repo/omarchy/os/x86_64/acl-1:2.3.2-1-x86_64.pkg.tar.zst ]] || fail "package not pooled"
[[ -f $ARCHCI_HOME/repo/omarchy/os/x86_64/acl-1:2.3.2-1-x86_64.pkg.tar.zst.buildsig ]] || fail "buildsig not kept"
[[ -e $ARCHCI_HOME/stage.needed ]] || fail "stage flag missing"
[[ -f $ARCHCI_HOME/logs/omarchy/acl/1:2.3.2-1/x86_64/attempt-1.log ]] || fail "log not archived"
[[ ! -e $inc ]] || fail "incoming not cleaned"
[[ $("$next") == "5 omarchy x86_64 libsigc++ "* ]] || fail "built package must not be outstanding"

echo "--- report failure, retry, give up"
id=$(claim_id worker-2 x86_64)
[[ $id == *omarchy,libsigc++,* ]] || fail "expected libsigc++ next, got $id"
"$job" report "$id" failure
[[ -f $ARCHCI_HOME/queue/failed/$id.job ]] || fail "not in failed/"
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
[[ $("$next") == "5 omarchy x86_64 libsigc++ 2.12.3-1 $(pkgcommit libsigc++) extra" ]] || fail "new libsigc++ version should be next: $("$next")"
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

echo "--- top --once and --json"
"$top" --once --no-journal | head -5
"$top" --json | ruby -rjson -e 'j=JSON.parse(STDIN.read); abort "bad json #{j["queue"]} #{j["outstanding"]}" unless j["queue"]["pending"] == 1 && j["outstanding"] == {"updates"=>0, "backlog"=>2} && j["built"]["omarchy-x86_64"] == 1 && j["arches"] == ["x86_64"] && j["repo"] == "omarchy" && j["pkgbuilds"]["packages"] == 3'

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
"$top" --once --no-journal | grep "^idle-host  *DigitalOcean  *riscv64  *0.50  *20  *10  *2  *1  *0  0.3.19-1$" >/dev/null || fail "archci-top must show an idle host from its poll, with the archci it runs: $("$top" --once --no-journal | grep idle-host)"
# shellcheck disable=SC2016  # a literal shell-looking stat, meant to be rejected
! ARCHCI_ARCHES="x86_64 riscv64" "$job" claim idle-host-1 riscv64 'load=$(true)' 2>/dev/null || fail "a malformed host stat must be refused"
touch -d '20 minutes ago' "$ARCHCI_HOME/hosts/idle-host-1"; sed -i "s/^seen=.*/seen=$(date -u -d '20 minutes ago' +%FT%TZ)/" "$ARCHCI_HOME/hosts/idle-host-1"
"$top" --once --no-journal | grep "^idle-host " >/dev/null && fail "a worker that stopped polling must drop out of the hosts table"
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
echo "ALL OK"
