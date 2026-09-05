#!/bin/bash
# shellcheck disable=SC2010,SC2012  # test assertions use ls on controlled temp fixtures
# Exercise the master queue on a throwaway ARCHCI_HOME without network or root:
# scan (from a fake state repo) -> just-in-time claim -> heartbeat -> report
# success/failure -> reap. Fake packages are minimal but real enough for repo-add.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export ARCHCI_CONF=/dev/null ARCHCI_HOME=$tmp/home ARCHCI_REPOS="core extra" ARCHCI_ARCH=x86_64
export ARCHCI_MAX_ATTEMPTS=2 ARCHCI_STALE_MINUTES=0 ARCHCI_RETRY_MINUTES=0 JOURNAL_STREAM=1
job=$here/../master/archci-job
scan=$here/../master/archci-scan
next=$here/../master/archci-next
status=$here/../master/archci-status
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

echo "--- scan: syncs state only, stores no backlog"
"$scan"
(( $(ls "$ARCHCI_HOME/queue/pending" | wc -l) == 0 )) || fail "scan must not create pending jobs"
[[ $("$next") == "5 core acl 1:2.3.2-1 1-2.3.2-1 1111111111111111111111111111111111111111" ]] || fail "archci-next: $("$next")"
"$status" --json | ruby -rjson -e 'j=JSON.parse(STDIN.read); abort "outstanding" unless j["outstanding"] == {"updates"=>0, "backlog"=>3}'

echo "--- claim picks the next outstanding package just in time"
out=$("$job" claim worker-1)
id=$(sed -n 's/^id=//p' <<<"$out")
[[ $id == 5-*-core,acl,1:2.3.2-1 ]] || fail "expected acl first (sorted), got $id"
[[ $("$next") == "5 core linux "* ]] || fail "a running package must not be offered again"
grep -q '^attempt=1$' <<<"$out" || fail "attempt should be 1"
[[ -f $ARCHCI_HOME/queue/running/$id.job ]] || fail "job not in running/"
"$job" heartbeat "$id"
! "$job" heartbeat "9-1-core,nope,1-1" 2>/dev/null || fail "heartbeat of unknown job must fail"

echo "--- report success pools packages and their builder signatures"
inc=$ARCHCI_HOME/incoming/$id
echo "log" >"$inc/build.log"
mkpkg "$inc" acl 1:2.3.2-1
mkpkg "$inc" acl-debug 1:2.3.2-1
: >"$inc/acl-1:2.3.2-1-x86_64.pkg.tar.zst.buildsig"   # carried through to the signer
"$job" report "$id" success
[[ -f $ARCHCI_HOME/queue/done/$id.job ]] || fail "job not in done/"
[[ $(<"$ARCHCI_HOME/built/core-x86_64/acl") == "1:2.3.2-1 1111111111111111111111111111111111111111" ]] || fail "built record wrong"
[[ -f $ARCHCI_HOME/repo/core/os/x86_64/acl-1:2.3.2-1-x86_64.pkg.tar.zst ]] || fail "package not pooled"
[[ -f $ARCHCI_HOME/repo/core/os/x86_64/acl-1:2.3.2-1-x86_64.pkg.tar.zst.buildsig ]] || fail "buildsig not kept"
[[ -e $ARCHCI_HOME/stage.needed ]] || fail "stage flag missing"
[[ -f $ARCHCI_HOME/logs/core/acl/1:2.3.2-1/attempt-1.log ]] || fail "log not archived"
[[ ! -e $inc ]] || fail "incoming not cleaned"
[[ $("$next") == "5 core linux "* ]] || fail "built package must not be outstanding"

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
[[ $("$next") == "5 extra libsigc++ "* ]] || fail "a final failure at the same commit must be skipped"

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

echo "--- a new upstream version supersedes a pending job and a final failure"
echo "libsigc++ 2.12.3-1 2.12.3-1 8888888888888888888888888888888888888888" >"$state/extra-x86_64/libsigc++"
echo "linux 7.2.4.arch1-1 7.2.4.arch1-1 2222222222222222222222222222222222222222" >"$state/core-x86_64/linux"
git -C "$state" -c user.name=t -c user.email=t@t commit -qam bump
"$scan"
"$job" reap
ls "$ARCHCI_HOME/queue/pending" | grep -q 'libsigc++,2.12.2-1' && fail "superseded pending job not dropped"
(( $(ls "$ARCHCI_HOME/queue/failed" | wc -l) == 0 )) || fail "superseded final failure not dropped"
[[ $("$next") == "5 core linux 7.2.4.arch1-1 "* ]] || fail "new linux release should be next: $("$next")"
"$job" enqueue core acl 0
ls "$ARCHCI_HOME/queue/pending" | grep -q '^0-.*core,acl' || fail "manual enqueue"

echo "--- ssh forced command + restricted rsync upload"
cat >"$tmp/fakessh" <<'SH'
#!/bin/bash
shift
SSH_ORIGINAL_COMMAND="$*" exec "$ARCHCI_SHELL"
SH
chmod +x "$tmp/fakessh"
export ARCHCI_SHELL=$here/../master/archci-shell
id=$(sed -n 's/^id=//p' < <("$tmp/fakessh" master claim worker-5))
[[ -n $id ]] || fail "claim through archci-shell"
mkdir -p "$tmp/out"; echo hi >"$tmp/out/build.log"; mkpkg "$tmp/out" acl 1:2.3.2-1
rsync -a -e "$tmp/fakessh" "$tmp/out/" "master:$id/" || fail "rsync via rrsync"
[[ -f $ARCHCI_HOME/incoming/$id/build.log ]] || fail "upload did not land in incoming/"
! rsync -a -e "$tmp/fakessh" "$tmp/out/" "master:../escape/" 2>/dev/null || fail "rrsync must refuse paths outside incoming"
! "$tmp/fakessh" master reap 2>/dev/null || fail "shell must refuse non-worker commands"
"$tmp/fakessh" master report "$id" success
[[ -f $ARCHCI_HOME/queue/done/$id.job ]] || fail "report through shell"

echo "--- signing gate: two-stage builder + release signatures (real gpg)"
gpgb=$tmp/gpg-builder gpgk=$tmp/gpg-keyring gpgr=$tmp/gpg-release gpgx=$tmp/gpg-attacker relpub=$tmp/gpg-relpub
for h in "$gpgb" "$gpgk" "$gpgr" "$gpgx" "$relpub"; do mkdir -p "$h"; chmod 700 "$h"; done
gpg --homedir "$gpgb" --batch --pinentry-mode loopback --passphrase '' --quick-generate-key 'archci-builder <b@t>' ed25519 sign never 2>/dev/null
gpg --homedir "$gpgr" --batch --pinentry-mode loopback --passphrase '' --quick-generate-key 'archci-release <r@t>' ed25519 sign never 2>/dev/null
gpg --homedir "$gpgx" --batch --pinentry-mode loopback --passphrase '' --quick-generate-key 'evil <e@t>' ed25519 sign never 2>/dev/null
gpg --homedir "$gpgb" --armor --export b@t | gpg --homedir "$gpgk" --batch --import 2>/dev/null   # trust only the real builder
mkpkg "$tmp" gate 1-1; pk=$tmp/gate-1-1-x86_64.pkg.tar.zst
gpg --homedir "$gpgb" --batch --detach-sign -u archci-builder -o "$pk.buildsig" "$pk"
gpg --homedir "$gpgk" --batch --verify "$pk.buildsig" "$pk" 2>/dev/null || fail "authorized builder signature must verify"
gpg --homedir "$gpgx" --batch --detach-sign -u evil -o "$tmp/evil.buildsig" "$pk"
! gpg --homedir "$gpgk" --batch --verify "$tmp/evil.buildsig" "$pk" 2>/dev/null || fail "unknown builder key must be rejected"
gpg --homedir "$gpgr" --batch --pinentry-mode loopback --detach-sign -u archci-release -o "$pk.sig" "$pk"
gpg --homedir "$gpgr" --armor --export r@t | gpg --homedir "$relpub" --batch --import 2>/dev/null
gpg --homedir "$relpub" --batch --verify "$pk.sig" "$pk" 2>/dev/null || fail "release signature must verify for clients"
printf tamper >>"$pk"
! gpg --homedir "$relpub" --batch --verify "$pk.sig" "$pk" 2>/dev/null || fail "tampered package must fail release verification"

echo "--- R2 transport: master stages, signer verifies+signs+publishes (fake rclone)"
# A faithful stand-in for rclone: every remote is a local path.
cat >"$tmp/rclone" <<'SH'
#!/bin/bash
sub=""; pos=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --transfers|--checkers|--config|--stats|--timeout|--contimeout) shift 2;;
    -R|--*) shift;;
    *) [[ -z $sub ]] && sub=$1 || pos+=("$1"); shift;;
  esac
done
case $sub in
  lsf) [[ -d ${pos[0]} ]] && (cd "${pos[0]}" && find . -type f -printf '%P\n');;
  copyto) [[ -f ${pos[0]} ]] || exit 1; mkdir -p "$(dirname "${pos[1]}")"; cp "${pos[0]}" "${pos[1]}";;
  deletefile) rm -f "${pos[0]}";;
  move) if [[ -d ${pos[0]} ]]; then (cd "${pos[0]}" && find . -type f -printf '%P\n') | while IFS= read -r f; do
          mkdir -p "$(dirname "${pos[1]}/$f")"; mv "${pos[0]}/$f" "${pos[1]}/$f"; done; fi;;
esac
exit 0
SH
chmod +x "$tmp/rclone"; export PATH="$tmp:$PATH"

R2=$tmp/r2; staging=$R2/staging release=$R2/release
export ARCHCI_R2_STAGING=$staging ARCHCI_R2_RELEASE=$release ARCHCI_RCLONE_CONFIG=/dev/null
# reuse the trusted builder keyring ($gpgk) and release key ($gpgr) from above
export ARCHCI_RELEASE_GNUPGHOME=$gpgr ARCHCI_RELEASE_KEY=archci-release
export ARCHCI_BUILDER_KEYRING=$gpgk ARCHCI_SIGNER_HOME=$tmp/signer
mkdir -p "$ARCHCI_SIGNER_HOME"

# a good package (built + builder-signed by the trusted key) lands in the master pool
mkpkg "$ARCHCI_HOME/repo/core/os/x86_64" hello 1-1
hp=$ARCHCI_HOME/repo/core/os/x86_64/hello-1-1-x86_64.pkg.tar.zst
gpg --homedir "$gpgb" --batch --detach-sign -u archci-builder -o "$hp.buildsig" "$hp"
# an untrusted package (signed by the attacker key) also lands in the pool
mkpkg "$ARCHCI_HOME/repo/core/os/x86_64" evil 1-1
ep=$ARCHCI_HOME/repo/core/os/x86_64/evil-1-1-x86_64.pkg.tar.zst
gpg --homedir "$gpgx" --batch --detach-sign -u evil -o "$ep.buildsig" "$ep"

"$here/../master/archci-stage" --force
[[ ! -e $hp && ! -e $ep ]] || fail "stage must move packages out of the pool"
[[ -f $staging/core/os/x86_64/hello-1-1-x86_64.pkg.tar.zst.buildsig ]] || fail "buildsig not staged"

"$here/../signer/archci-sign"
# the trusted package is released and signed; the attacker package is rejected
rel=$release/core/os/x86_64
[[ -f $rel/hello-1-1-x86_64.pkg.tar.zst && -f $rel/hello-1-1-x86_64.pkg.tar.zst.sig ]] || fail "trusted package not released+signed"
[[ ! -e $release/core/os/x86_64/evil-1-1-x86_64.pkg.tar.zst ]] || fail "attacker package must not be released"
[[ -f $rel/core.db.tar.gz && -f $rel/core.db ]] || fail "release database (both names) missing"
bsdtar -xOf "$rel/core.db.tar.gz" '*/desc' | grep -qxF 'hello-1-1-x86_64.pkg.tar.zst' || fail "hello not in release db"
gpg --homedir "$relpub" --batch --verify "$rel/hello-1-1-x86_64.pkg.tar.zst.sig" "$rel/hello-1-1-x86_64.pkg.tar.zst" 2>/dev/null || fail "released signature must verify for clients"
# staging is drained (both the released and the rejected package removed)
[[ -z $(find "$staging" -name '*.pkg.tar.zst' 2>/dev/null) ]] || fail "staging must be drained"

echo "--- status"
"$status" | head -5
"$status" --json | ruby -rjson -e 'j=JSON.parse(STDIN.read); abort "bad json" unless j["queue"]["pending"] == 0 && j["outstanding"] == {"updates"=>0, "backlog"=>2} && j["built"]["core"] == 1'
echo "ALL OK"
