#!/bin/bash
# Exercise the master queue on a throwaway ARCHCI_HOME without network or root:
# scan (from a fake state repo) -> claim -> heartbeat -> report success/failure
# -> reap. Fake packages are empty files; repo-add still builds a real db.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export ARCHCI_CONF=/dev/null ARCHCI_HOME=$tmp/home ARCHCI_REPOS="core extra" ARCHCI_ARCH=x86_64
export ARCHCI_MAX_ATTEMPTS=2 ARCHCI_STALE_MINUTES=0 ARCHCI_RETRY_MINUTES=0 JOURNAL_STREAM=1
job=$here/../bin/archci-job
scan=$here/../bin/archci-scan
status=$here/../bin/archci-status
fail() { echo "FAIL: $*" >&2; exit 1; }
# mkpkg DIR NAME VERSION -- smallest thing repo-add accepts as a package
mkpkg() {
	local d=$tmp/mkpkg; rm -rf "$d"; mkdir -p "$d"
	printf 'pkgname = %s\npkgbase = %s\npkgver = %s\npkgdesc = fake\nurl = x\nbuilddate = 1\npackager = t\nsize = 0\narch = x86_64\n' \
		"$2" "${2%-debug}" "$3" >"$d/.PKGINFO"
	bsdtar -C "$d" -cf - .PKGINFO | zstd -q >"$1/$2-$3-x86_64.pkg.tar.zst"
}

mkdir -p "$ARCHCI_HOME"/{queue/{pending,running,done,failed},built,logs,lock,incoming,repo}
# fake packaging/state repo
state=$tmp/state
mkdir -p "$state"/{core,extra}-x86_64
git -C "$state" init -q -b main
echo "linux 7.2.3.arch1-2 7.2.3.arch1-2 5ad4989865a52c7b0a7b49f4117714e0b2b31d3d" >"$state/core-x86_64/linux"
echo "libsigc++ 2.12.2-1 2.12.2-1 7cb18d882646b8e41e895f98b79be961178c3d38" >"$state/extra-x86_64/libsigc++"
echo "acl 1:2.3.2-1 1-2.3.2-1 1111111111111111111111111111111111111111" >"$state/core-x86_64/acl"
git -C "$state" add -A && git -C "$state" -c user.name=t -c user.email=t@t commit -q -m init
export ARCHCI_STATE_URL=file://$state

echo "--- scan"
"$scan"
(( $(ls "$ARCHCI_HOME/queue/pending" | wc -l) == 3 )) || fail "expected 3 pending jobs"
"$scan"
(( $(ls "$ARCHCI_HOME/queue/pending" | wc -l) == 3 )) || fail "second scan must not duplicate jobs"

echo "--- claim"
out=$("$job" claim worker-1)
id=$(sed -n 's/^id=//p' <<<"$out")
[[ $id == 5-*-core,acl,1:2.3.2-1 ]] || fail "expected acl first (sorted), got $id"
grep -q '^attempt=1$' <<<"$out" || fail "attempt should be 1"
[[ -f $ARCHCI_HOME/queue/running/$id.job ]] || fail "job not in running/"
"$job" heartbeat "$id"
! "$job" heartbeat "9-1-core,nope,1-1" 2>/dev/null || fail "heartbeat of unknown job must fail"

echo "--- report success"
inc=$ARCHCI_HOME/incoming/$id
echo "log" >"$inc/build.log"
mkpkg "$inc" acl 1:2.3.2-1
mkpkg "$inc" acl-debug 1:2.3.2-1
"$job" report "$id" success
[[ -f $ARCHCI_HOME/queue/done/$id.job ]] || fail "job not in done/"
[[ $(<"$ARCHCI_HOME/built/core-x86_64/acl") == "1:2.3.2-1 1111111111111111111111111111111111111111" ]] || fail "built record wrong"
[[ -f $ARCHCI_HOME/repo/core/os/x86_64/core.db.tar.gz ]] || fail "no core db"
[[ -f $ARCHCI_HOME/repo/core-debug/os/x86_64/core-debug.db.tar.gz ]] || fail "no debug db"
[[ -f $ARCHCI_HOME/repo/core/os/x86_64/acl-1:2.3.2-1-x86_64.pkg.tar.zst ]] || fail "package not moved"
[[ -f $ARCHCI_HOME/logs/core/acl/1:2.3.2-1/attempt-1.log ]] || fail "log not archived"
[[ -e $ARCHCI_HOME/publish.needed ]] || fail "publish flag missing"
[[ ! -e $inc ]] || fail "incoming not cleaned"

echo "--- report failure, retry, give up"
id=$(sed -n 's/^id=//p' < <("$job" claim worker-2))
[[ $id == *core,linux,* ]] || fail "expected linux next, got $id"
"$job" report "$id" failure
[[ -f $ARCHCI_HOME/queue/failed/$id.job ]] || fail "not in failed/"
grep -q '^final=' "$ARCHCI_HOME/queue/failed/$id.job" && fail "should not be final yet"
"$job" reap
[[ -f $ARCHCI_HOME/queue/pending/$id.job ]] || fail "reaper should have requeued"
grep -q '^attempt=1$' "$ARCHCI_HOME/queue/pending/$id.job" || fail "attempt kept across requeue"
id2=$(sed -n 's/^id=//p' < <("$job" claim worker-2))
[[ $id2 == "$id" ]] || fail "retry should be claimed first (prio 5 vs libsigc++ prio 5, older ts)"
"$job" report "$id" failure
grep -q '^final=1$' "$ARCHCI_HOME/queue/failed/$id.job" || fail "should be final after max attempts"
"$job" reap
[[ -f $ARCHCI_HOME/queue/failed/$id.job ]] || fail "final job must stay failed"
"$scan"
[[ -f $ARCHCI_HOME/queue/failed/$id.job ]] || fail "scan must not re-enqueue a final failure at the same commit"

echo "--- success reported with empty upload counts as failure"
id=$(sed -n 's/^id=//p' < <("$job" claim worker-3))
[[ $id == *libsigc++* ]] || fail "expected libsigc++, got $id"
"$job" report "$id" success
[[ -f $ARCHCI_HOME/queue/failed/$id.job ]] || fail "empty success must fail"

echo "--- stale running job is reaped; abandoned does not count"
"$job" retry "$id"
id=$(sed -n 's/^id=//p' < <("$job" claim worker-4))
touch -d '1 hour ago' "$ARCHCI_HOME/queue/running/$id.job"
"$job" reap
[[ -f $ARCHCI_HOME/queue/pending/$id.job ]] || fail "stale job not requeued"
id=$(sed -n 's/^id=//p' < <("$job" claim worker-4))
"$job" report "$id" abandoned
grep -q '^attempt=1$' "$ARCHCI_HOME/queue/pending/$id.job" || fail "abandoned must not count an attempt"

echo "--- new upstream version supersedes a pending job"
echo "libsigc++ 2.12.3-1 2.12.3-1 8888888888888888888888888888888888888888" >"$state/extra-x86_64/libsigc++"
git -C "$state" -c user.name=t -c user.email=t@t commit -qam bump
"$scan"
ls "$ARCHCI_HOME/queue/pending" | grep -q 'libsigc++,2.12.3-1' || fail "new version not enqueued"
ls "$ARCHCI_HOME/queue/pending" | grep -q 'libsigc++,2.12.2-1' && fail "old pending job not dropped"
"$job" enqueue core acl 0
ls "$ARCHCI_HOME/queue/pending" | grep -q '^0-.*core,acl' || fail "manual enqueue"

echo "--- ssh forced command + restricted rsync upload"
cat >"$tmp/fakessh" <<'SH'
#!/bin/bash
shift
SSH_ORIGINAL_COMMAND="$*" exec "$ARCHCI_SHELL"
SH
chmod +x "$tmp/fakessh"
export ARCHCI_SHELL=$here/../bin/archci-shell
id=$(sed -n 's/^id=//p' < <("$tmp/fakessh" master claim worker-5))
[[ -n $id ]] || fail "claim through archci-shell"
mkdir -p "$tmp/out"; echo hi >"$tmp/out/build.log"; mkpkg "$tmp/out" acl 1:2.3.2-1
rsync -a -e "$tmp/fakessh" "$tmp/out/" "master:$id/" || fail "rsync via rrsync"
[[ -f $ARCHCI_HOME/incoming/$id/build.log ]] || fail "upload did not land in incoming/"
! rsync -a -e "$tmp/fakessh" "$tmp/out/" "master:../escape/" 2>/dev/null || fail "rrsync must refuse paths outside incoming"
! "$tmp/fakessh" master reap 2>/dev/null || fail "shell must refuse non-worker commands"
"$tmp/fakessh" master report "$id" success
[[ -f $ARCHCI_HOME/queue/done/$id.job ]] || fail "report through shell"

echo "--- status"
"$status" | head -5
"$status" --json | ruby -rjson -e 'j=JSON.parse(STDIN.read); abort "bad json" unless j["queue"]["pending"] == 1 && j["built"]["core"] == 1'
echo "ALL OK"
