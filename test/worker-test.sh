#!/bin/bash
# worker-test.sh -- archci-worker end to end against a real master queue in a
# temp dir, with ssh, systemctl, journalctl and the build itself faked:
#   * claim -> "build" -> upload through the real forced command and rrsync ->
#     report -> the master pools the package and records it built
#   * a master outage after the build: the results are kept and delivered when
#     the master is back (ssh exit 255 for a while)
#   * the worker re-executes itself when its script changes on disk
# The worker runs from a copy of the tree (it watches its own files), talks to
# the master through a fake ssh that runs archci-shell, and "builds" through a
# fake systemctl that writes the result file and a fake package.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
tmp=$(mktemp -d)
worker_pid=''
cleanup() { [[ -n $worker_pid ]] && kill "$worker_pid" 2>/dev/null; sleep 0.2; rm -rf "$tmp"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for tool in rrsync bsdtar zstd rsync git; do command -v $tool >/dev/null || { echo "skip: $tool missing"; exit 0; }; done

# --- the master: a real queue with one outstanding package -------------------
export ARCHCI_CONF=/dev/null ARCHCI_HOME=$tmp/home ARCHCI_REPO=omarchy ARCHCI_ARCH=x86_64 JOURNAL_STREAM=1
export ARCHCI_MAX_ATTEMPTS=3 ARCHCI_STALE_MINUTES=30 ARCHCI_RETRY_MINUTES=0
mkdir -p "$ARCHCI_HOME"/{queue/{pending,running,done,failed},built,logs,lock,incoming,repo}
pkgs=$tmp/pkgs
git -C "$tmp" init -q -b master "$pkgs"
mkdir -p "$pkgs/pkgbuilds/acl/.omarchy"
printf 'pkgname=acl\npkgver=2.4.0\npkgrel=1\narch=(x86_64)\n' >"$pkgs/pkgbuilds/acl/PKGBUILD"
printf '{"source": "arch"}\n' >"$pkgs/pkgbuilds/acl/.omarchy/package.json"
git -C "$pkgs" add -A && git -C "$pkgs" -c user.name=t -c user.email=t@t commit -q -m init
export ARCHCI_PKGBUILDS_URL=file://$pkgs
"$here/../master/archci-scan" >/dev/null

# --- the worker: its own copy of the tree, fakes first on PATH ----------------
tree=$tmp/tree
mkdir -p "$tree" "$tmp/bin" "$tmp/whome"
cp -a "$here/../lib" "$here/../worker" "$tree/"
export ARCHCI_WORKER_HOME=$tmp/whome ARCHCI_WORKER_KEY=$tmp/key ARCHCI_MASTER=archci@master
export ARCHCI_IDLE_SLEEP=1 ARCHCI_HEARTBEAT_SECONDS=2 ARCHCI_DELIVERY_RETRY_SECONDS=1 ARCHCI_CHROOTS=/
export ARCHCI_SHELL=$here/../master/archci-shell HOSTNAME=testbox
: >"$ARCHCI_WORKER_KEY"
# ssh: drop the options, run the forced command as the master would; while
# $tmp/master-down exists it fails the way a dead host does (255)
cat >"$tmp/bin/ssh" <<'SH'
#!/bin/bash
[[ -e $TESTTMP/master-down ]] && exit 255
while [[ $1 == -* ]]; do case $1 in -i|-o|-l|-p) shift 2;; *) shift;; esac; done
shift   # the host
SSH_ORIGINAL_COMMAND="$*" exec "$ARCHCI_SHELL"
SH
# systemctl: "start archci-build@NAME" is the build: a result file and a package
cat >"$tmp/bin/systemctl" <<'SH'
#!/bin/bash
case $1 in
  start)
    name=${2#archci-build@}; name=${name%.service}
    out=$ARCHCI_WORKER_HOME/jobs/$name/out
    mkdir -p "$out/p"
    printf 'pkgname = acl\npkgbase = acl\npkgver = 2.4.0-1\npkgdesc = fake\nurl = x\nbuilddate = 1\npackager = t\nsize = 0\narch = x86_64\n' >"$out/p/.PKGINFO"
    bsdtar -C "$out/p" -cf - .PKGINFO | zstd -q >"$out/acl-2.4.0-1-x86_64.pkg.tar.zst"
    rm -rf "$out/p"
    : >"$out/acl-2.4.0-1-x86_64.pkg.tar.zst.buildsig"
    echo success >"$out/result"
    [[ -e $TESTTMP/down-after-build ]] && touch "$TESTTMP/master-down"
    exit 0;;
  show) exit 0;;   # no cgroup: no job stats
  *) exit 0;;
esac
SH
printf '#!/bin/bash\necho "fake build log"\n' >"$tmp/bin/journalctl"
chmod +x "$tmp/bin"/*
export TESTTMP=$tmp PATH=$tmp/bin:$PATH

start_worker() {
	"$tree/worker/archci-worker" 1 >"$tmp/worker.log" 2>&1 &
	worker_pid=$!
}
wait_for() {   # wait_for SECONDS PATTERN FILE
	local i; for ((i = 0; i < $1 * 10; i++)); do grep -q "$2" "$3" 2>/dev/null && return 0; sleep 0.1; done; return 1
}

echo "--- claim, build, upload, report: the master pools the package"
start_worker
wait_for 20 'omarchy,acl,2.4.0-1,x86_64: success after' "$tmp/worker.log" || fail "the job did not finish: $(<"$tmp/worker.log")"
wait_for 10 . "$ARCHCI_HOME/built/omarchy-x86_64/acl" || fail "the master did not record acl as built: $(<"$tmp/worker.log")"
[[ $(<"$ARCHCI_HOME/built/omarchy-x86_64/acl") == "2.4.0-1 "* ]] || fail "built record wrong: $(<"$ARCHCI_HOME/built/omarchy-x86_64/acl")"
[[ -f $ARCHCI_HOME/repo/omarchy/os/x86_64/acl-2.4.0-1-x86_64.pkg.tar.zst ]] || fail "package not pooled"
(( $(find "$ARCHCI_HOME/queue/done" -type f | wc -l) == 1 )) || fail "job not in done/"
# the worker removes the job directory after its report; give a slow host a moment
for ((i = 0; i < 100; i++)); do
	leftover=$(find "$ARCHCI_WORKER_HOME/jobs" -mindepth 1 -maxdepth 1 -not -name 'claim*')
	[[ -z $leftover ]] && break; sleep 0.1
done
[[ -z $leftover ]] || fail "job directory not cleaned up: $leftover"
grep -q 'building .* as archci-build@' "$tmp/worker.log" || fail "no build log line"
kill "$worker_pid"; wait "$worker_pid" 2>/dev/null || true; worker_pid=''

echo "--- master unreachable after the build: results kept, delivered when it is back"
rm -f "$ARCHCI_HOME/built/omarchy-x86_64/acl"; rm -f "$ARCHCI_HOME"/queue/done/*
touch "$tmp/down-after-build"
start_worker
wait_for 20 "master unreachable, keeping .* results until it is back" "$tmp/worker.log" || fail "the worker did not report the outage: $(<"$tmp/worker.log")"
sleep 3   # a few retries against the dead master
[[ -d $ARCHCI_WORKER_HOME/jobs/omarchy-acl-2.4.0-1-x86_64-a1/out ]] || fail "results dropped while the master was down"
[[ ! -e $ARCHCI_HOME/built/omarchy-x86_64/acl ]] || fail "nothing can have been delivered while ssh failed"
rm -f "$tmp/master-down" "$tmp/down-after-build"
wait_for 20 'delivered after [0-9]* tries' "$tmp/worker.log" || fail "results not delivered after the master came back: $(<"$tmp/worker.log")"
wait_for 10 . "$ARCHCI_HOME/built/omarchy-x86_64/acl" || fail "the master did not record the late delivery"
grep -c 'master unreachable, keeping' "$tmp/worker.log" | grep -x 1 >/dev/null || fail "the outage must be logged once, not per try"
kill "$worker_pid"; wait "$worker_pid" 2>/dev/null || true; worker_pid=''

echo "--- the worker re-executes itself when its script changes on disk"
start_worker
wait_for 10 'worker testbox-1 (x86_64) started' "$tmp/worker.log" || fail "worker did not start"
sleep 1; install -m 755 "$here/../worker/archci-worker" "$tree/worker/archci-worker"   # a new inode, as pacman leaves
wait_for 10 'changed on disk; restarting on the new code' "$tmp/worker.log" || fail "the worker did not notice its new code: $(<"$tmp/worker.log")"
for ((i = 0; i < 100; i++)); do (( $(grep -c 'started, master' "$tmp/worker.log") == 2 )) && break; sleep 0.1; done
(( $(grep -c 'started, master' "$tmp/worker.log") == 2 )) || fail "the worker did not come back after the restart: $(<"$tmp/worker.log")"
kill "$worker_pid"; wait "$worker_pid" 2>/dev/null || true; worker_pid=''
echo "ALL OK"
