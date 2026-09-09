#!/bin/bash
# shellcheck disable=SC2010,SC2012  # test assertions use ls on controlled temp fixtures
# Exercise the master queue on a throwaway ARCHCI_HOME without network or root:
# scan (from a fake PKGBUILD repository) -> just-in-time claim -> heartbeat ->
# report success/failure -> reap. Fake packages are minimal but real enough for
# repo-add.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export ARCHCI_CONF=/dev/null ARCHCI_HOME=$tmp/home ARCHCI_REPO=omarchy ARCHCI_ARCH=x86_64
export ARCHCI_MAX_ATTEMPTS=2 ARCHCI_STALE_MINUTES=0 ARCHCI_RETRY_MINUTES=0 JOURNAL_STREAM=1
job=$here/../master/archci-job
scan=$here/../master/archci-scan
next=$here/../master/archci-next
status=$here/../master/archci-status
fail() { echo "FAIL: $*" >&2; exit 1; }
# mkpkg DIR NAME VERSION [ARCH] -- smallest thing repo-add accepts as a package
mkpkg() {
	local d=$tmp/mkpkg arch=${4:-x86_64}; rm -rf "$d"; mkdir -p "$d"
	printf 'pkgname = %s\npkgbase = %s\npkgver = %s\npkgdesc = fake\nurl = x\nbuilddate = 1\npackager = t\nsize = 0\narch = %s\n' \
		"$2" "${2%-debug}" "$3" "$arch" >"$d/.PKGINFO"
	bsdtar -C "$d" -cf - .PKGINFO | zstd -q >"$1/$2-$3-$arch.pkg.tar.zst"
}

mkdir -p "$ARCHCI_HOME"/{queue/{pending,running,done,failed},built,logs,lock,incoming,repo}
# fake PKGBUILD repository in the omarchy-pkgs layout: pkgbuilds/<name>/PKGBUILD
# plus .omarchy/package.json
pkgs=$tmp/pkgs
git -C "$tmp" init -q -b master "$pkgs"
# mkpkgbuild NAME VERSION [ARCH] [JSON] -- VERSION is [epoch:]pkgver-pkgrel
mkpkgbuild() {
	local d=$pkgs/pkgbuilds/$1 v=$2 epoch='' arch=${3:-x86_64}
	[[ $v == *:* ]] && { epoch=${v%%:*}; v=${v#*:}; }
	mkdir -p "$d/.omarchy"
	printf 'pkgname=%s\npkgver=%s\npkgrel=%s\n%sarch=(%s)\n' "$1" "${v%-*}" "${v##*-}" "${epoch:+epoch=$epoch
}" "$arch" >"$d/PKGBUILD"
	printf '%s\n' "${4:-{\"source\": \"arch\"\}}" >"$d/.omarchy/package.json"
}
commit_pkgs() { git -C "$pkgs" add -A && git -C "$pkgs" -c user.name=t -c user.email=t@t commit -q -m "$1"; }
pkgcommit() { git -C "$pkgs" log -1 --format=%H -- "pkgbuilds/$1"; }
mkpkgbuild linux 7.2.3.arch1-2
mkpkgbuild libsigc++ 2.12.2-1
mkpkgbuild acl 1:2.3.2-1
mkpkgbuild skipped 1-1 x86_64 '{"source": "local", "skip_build": true}'
commit_pkgs init
export ARCHCI_PKGBUILDS_URL=file://$pkgs

echo "--- scan: syncs the PKGBUILD repository only, stores no backlog"
"$scan"
(( $(ls "$ARCHCI_HOME/queue/pending" | wc -l) == 0 )) || fail "scan must not create pending jobs"
[[ -d $ARCHCI_HOME/pkgbuilds/.git ]] || fail "scan must clone the PKGBUILD repository"
[[ $("$next") == "5 omarchy x86_64 acl 1:2.3.2-1 $(pkgcommit acl) extra" ]] || fail "archci-next: $("$next")"
"$here/../master/archci-pkgs" | grep -q '^skipped 1-1 .* skip -$' || fail "archci-pkgs must list skip_build packages as skip"
[[ $("$next" | wc -l) == 1 ]] || fail "next prints one line"
! ARCHCI_PKG_SOURCES=local "$next" | grep -q . || fail "ARCHCI_PKG_SOURCES must filter by package.json source"
[[ $(ARCHCI_PKG_SOURCES=local ARCHCI_PKG_ALSO=acl "$next") == "5 omarchy x86_64 acl "* ]] || fail "ARCHCI_PKG_ALSO must build a named package regardless of source"
"$status" --json | ruby -rjson -e 'j=JSON.parse(STDIN.read); abort "outstanding" unless j["outstanding"] == {"updates"=>0, "backlog"=>3}'

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
"$job" heartbeat "$id"
"$job" heartbeat "$id" load=1.50 mem=42 disk=61 cpus=4
grep -q '^load=1.50$' "$ARCHCI_HOME/queue/running/$id.job" || fail "heartbeat stats not kept with the job"
"$job" heartbeat "$id" load=0.10 mem=40 disk=61 cpus=4 cpu=3.7 rss=1840 peak=2100 build=5.0G
grep -q '^build=5.0G$' "$ARCHCI_HOME/queue/running/$id.job" || fail "job stats not kept"
(( $(grep -c '^load=' "$ARCHCI_HOME/queue/running/$id.job") == 1 )) || fail "heartbeat stats must be replaced, not appended"
# shellcheck disable=SC2016  # a literal shell-looking stat, meant to be rejected
! "$job" heartbeat "$id" 'load=$(rm -rf /)' 2>/dev/null || fail "a malformed stat must be refused"
! "$job" heartbeat "9-1-omarchy,nope,1-1,x86_64" 2>/dev/null || fail "heartbeat of unknown job must fail"
ARCHCI_REMOTE_JOURNAL=$tmp/no-journal "$here/../master/archci-top" --once | grep -q "^worker  *x86_64  *0.10 .* 4  *1  *1$" || fail "archci-top must show the host's arch, stats, threads, worker count and active workers"
printf '{"generated":"2026-01-01T00:00:00Z","staging":{"waiting":2,"oldest_s":90},"release":{"x86_64":{"updated":"2026-01-01T00:00:00Z","packages":63},"aarch64":{"updated":null,"packages":null}}}\n' >"$ARCHCI_HOME/signer.status"
ARCHCI_REMOTE_JOURNAL=$tmp/no-journal "$here/../master/archci-top" --once | grep -q "^signer: staging 2 pkg (oldest 1m30s)   release x86_64 63 pkg 00:00Z (.* ago)  aarch64 unreachable" || fail "archci-top must show the signer status from signer.status"
"$here/../master/archci-status" | grep -q "^  signer: 2 in staging (oldest 2 min)   release: x86_64 63 pkg @ 2026-01-01T00:00:00Z  aarch64 unreachable" || fail "archci-status must show the signer status"
ARCHCI_REMOTE_JOURNAL=$tmp/no-journal "$here/../master/archci-top" --once | grep -q " 3.7  1840M  2100M   5.0G " || fail "archci-top must show the job's cpu, memory and build size: $(ARCHCI_REMOTE_JOURNAL=$tmp/no-journal "$here/../master/archci-top" --once | grep worker-1)"

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
ARCHCI_REMOTE_JOURNAL=$tmp/no-journal "$here/../master/archci-top" --once | grep -q "^worker  *x86_64  *0.10 .* 4  *1  *0$" || fail "archci-top must show an idle host with its last heartbeat and no active workers"
[[ $(<"$ARCHCI_HOME/built/omarchy-x86_64/acl") == "1:2.3.2-1 $(pkgcommit acl)" ]] || fail "built record wrong"
[[ -f $ARCHCI_HOME/repo/omarchy/os/x86_64/acl-1:2.3.2-1-x86_64.pkg.tar.zst ]] || fail "package not pooled"
[[ -f $ARCHCI_HOME/repo/omarchy/os/x86_64/acl-1:2.3.2-1-x86_64.pkg.tar.zst.buildsig ]] || fail "buildsig not kept"
[[ -e $ARCHCI_HOME/stage.needed ]] || fail "stage flag missing"
[[ -f $ARCHCI_HOME/logs/omarchy/acl/1:2.3.2-1/x86_64/attempt-1.log ]] || fail "log not archived"
[[ ! -e $inc ]] || fail "incoming not cleaned"
[[ $("$next") == "5 omarchy x86_64 libsigc++ "* ]] || fail "built package must not be outstanding"

echo "--- report failure, retry, give up"
id=$(sed -n 's/^id=//p' < <("$job" claim worker-2 x86_64))
[[ $id == *omarchy,libsigc++,* ]] || fail "expected libsigc++ next, got $id"
"$job" report "$id" failure
[[ -f $ARCHCI_HOME/queue/failed/$id.job ]] || fail "not in failed/"
grep -q '^final=' "$ARCHCI_HOME/queue/failed/$id.job" && fail "should not be final yet"
"$job" reap
[[ -f $ARCHCI_HOME/queue/pending/$id.job ]] || fail "reaper should have requeued"
grep -q '^attempt=1$' "$ARCHCI_HOME/queue/pending/$id.job" || fail "attempt kept across requeue"
id2=$(sed -n 's/^id=//p' < <("$job" claim worker-2 x86_64))
[[ $id2 == "$id" ]] || fail "retry should be claimed first (prio 5 vs linux prio 5, older ts)"
"$job" report "$id" failure
grep -q '^final=1$' "$ARCHCI_HOME/queue/failed/$id.job" || fail "should be final after max attempts"
"$job" reap
[[ -f $ARCHCI_HOME/queue/failed/$id.job ]] || fail "final job must stay failed"
[[ $("$next") == "5 omarchy x86_64 linux "* ]] || fail "a final failure at the same commit must be skipped"

echo "--- success reported with empty upload counts as failure"
id=$(sed -n 's/^id=//p' < <("$job" claim worker-3 x86_64))
[[ $id == *linux* ]] || fail "expected linux, got $id"
"$job" report "$id" success
[[ -f $ARCHCI_HOME/queue/failed/$id.job ]] || fail "empty success must fail"

echo "--- stale running job is reaped; abandoned does not count"
"$job" retry "$id"
id=$(sed -n 's/^id=//p' < <("$job" claim worker-4 x86_64))
touch -d '1 hour ago' "$ARCHCI_HOME/queue/running/$id.job"
"$job" reap
[[ -f $ARCHCI_HOME/queue/pending/$id.job ]] || fail "stale job not requeued"
id=$(sed -n 's/^id=//p' < <("$job" claim worker-4 x86_64))
"$job" report "$id" abandoned
grep -q '^attempt=1$' "$ARCHCI_HOME/queue/pending/$id.job" || fail "abandoned must not count an attempt"

echo "--- a new commit of a package supersedes a pending job and a final failure"
mkpkgbuild linux 7.2.3.arch1-2 x86_64 '{"source": "arch", "note": "metadata only"}'   # same version, new commit
mkpkgbuild libsigc++ 2.12.3-1
commit_pkgs bump
"$scan"
"$job" reap
ls "$ARCHCI_HOME/queue/pending" | grep -q 'linux,7.2.3.arch1-2' && fail "superseded pending job not dropped"
(( $(ls "$ARCHCI_HOME/queue/failed" | wc -l) == 0 )) || fail "superseded final failure not dropped"
[[ $("$next") == "5 omarchy x86_64 libsigc++ 2.12.3-1 $(pkgcommit libsigc++) extra" ]] || fail "new libsigc++ version should be next: $("$next")"
"$job" enqueue acl 0
ls "$ARCHCI_HOME/queue/pending" | grep -q '^0-.*omarchy,acl' || fail "manual enqueue"
! "$job" enqueue skipped 0 2>/dev/null || true   # skip_build packages may still be enqueued by hand
ls "$ARCHCI_HOME/queue/pending" | grep -q 'omarchy,skipped,1-1' || fail "manual enqueue of a skip_build package"
rm -f "$ARCHCI_HOME"/queue/pending/*skipped*
! "$job" enqueue nosuch 0 2>/dev/null || fail "enqueue of an unknown package must fail"

echo "--- a same-version commit does not rebuild a built package"
mkpkgbuild acl 1:2.3.2-1 x86_64 '{"source": "arch", "note": "metadata only"}'
commit_pkgs acl-metadata
"$scan"
[[ $("$next") != *" acl "* ]] || fail "acl was built at this version; a metadata commit must not rebuild it"

echo "--- archci-authorize: forced-command lines in a root-owned file, deduplicated"
akf=$tmp/authorized_keys
ssh-keygen -q -t ed25519 -N '' -C worker-x -f "$tmp/wkey"
ARCHCI_AUTHORIZED_KEYS=$akf "$here/../master/archci-authorize" "$tmp/wkey.pub"
ARCHCI_AUTHORIZED_KEYS=$akf "$here/../master/archci-authorize" "$tmp/wkey.pub" 2>&1 | grep -q "already authorized" || fail "re-authorizing must be a no-op"
(( $(wc -l <"$akf") == 1 )) || fail "duplicate key line"
grep -q '^command="[^"]*/master/archci-shell",restrict,port-forwarding,permitopen="127.0.0.1:19532" ssh-ed25519 ' "$akf" || fail "authorized line lacks the forced command or tunnel options: $(<"$akf")"
# a line with stale options for a known key is rewritten, not duplicated
sed -i 's/,port-forwarding,permitopen="127.0.0.1:19532"//' "$akf"
ARCHCI_AUTHORIZED_KEYS=$akf "$here/../master/archci-authorize" "$tmp/wkey.pub" 2>&1 | grep -q "updated" || fail "stale options must be rewritten"
{ (( $(wc -l <"$akf") == 1 )) && grep -q 'permitopen' "$akf"; } || fail "rewrite left the file wrong: $(<"$akf")"
[[ $(stat -c %a "$akf") == 644 ]] || fail "authorized_keys should be world-readable, root-writable"
! ARCHCI_AUTHORIZED_KEYS=$akf "$here/../master/archci-authorize" 'not a key' 2>/dev/null || fail "garbage must be rejected"
# keys from the old per-user file are carried over once
mkdir -p "$ARCHCI_HOME/.ssh"; echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOldKeyOldKeyOldKeyOldKeyOldKeyOldKeyOldKeyOldKe old" >"$ARCHCI_HOME/.ssh/authorized_keys"
ARCHCI_AUTHORIZED_KEYS=$tmp/ak2 "$here/../master/archci-authorize" "$tmp/wkey.pub"
grep -q ' old$' "$tmp/ak2" && [[ -f $ARCHCI_HOME/.ssh/authorized_keys.migrated ]] || fail "old per-user keys not migrated"

echo "--- ssh forced command + restricted rsync upload"
cat >"$tmp/fakessh" <<'SH'
#!/bin/bash
shift
SSH_ORIGINAL_COMMAND="$*" exec "$ARCHCI_SHELL"
SH
chmod +x "$tmp/fakessh"
export ARCHCI_SHELL=$here/../master/archci-shell
id=$(sed -n 's/^id=//p' < <("$tmp/fakessh" master claim worker-5 x86_64))
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
mkpkg "$ARCHCI_HOME/repo/omarchy/os/x86_64" hello 1-1
hp=$ARCHCI_HOME/repo/omarchy/os/x86_64/hello-1-1-x86_64.pkg.tar.zst
gpg --homedir "$gpgb" --batch --detach-sign -u archci-builder -o "$hp.buildsig" "$hp"
# an untrusted package (signed by the attacker key) also lands in the pool
mkpkg "$ARCHCI_HOME/repo/omarchy/os/x86_64" evil 1-1
ep=$ARCHCI_HOME/repo/omarchy/os/x86_64/evil-1-1-x86_64.pkg.tar.zst
gpg --homedir "$gpgx" --batch --detach-sign -u evil -o "$ep.buildsig" "$ep"

"$here/../master/archci-stage" --force
[[ ! -e $hp && ! -e $ep ]] || fail "stage must move packages out of the pool"
[[ -f $staging/omarchy/os/x86_64/hello-1-1-x86_64.pkg.tar.zst.buildsig ]] || fail "buildsig not staged"

"$here/../signer/archci-sign"
# the trusted package is released and signed; the attacker package is rejected
rel=$release/omarchy/os/x86_64
[[ -f $rel/hello-1-1-x86_64.pkg.tar.zst && -f $rel/hello-1-1-x86_64.pkg.tar.zst.sig ]] || fail "trusted package not released+signed"
[[ ! -e $release/omarchy/os/x86_64/evil-1-1-x86_64.pkg.tar.zst ]] || fail "attacker package must not be released"
[[ -f $rel/omarchy.db.tar.gz && -f $rel/omarchy.db ]] || fail "release database (both names) missing"
bsdtar -xOf "$rel/omarchy.db.tar.gz" '*/desc' | grep -qxF 'hello-1-1-x86_64.pkg.tar.zst' || fail "hello not in release db"
gpg --homedir "$relpub" --batch --verify "$rel/hello-1-1-x86_64.pkg.tar.zst.sig" "$rel/hello-1-1-x86_64.pkg.tar.zst" 2>/dev/null || fail "released signature must verify for clients"
# staging is drained (both the released and the rejected package removed)
[[ -z $(find "$staging" -name '*.pkg.tar.zst' 2>/dev/null) ]] || fail "staging must be drained"

echo "--- sign-health: quiet when healthy, warns on lock or backlog"
health=$here/../signer/archci-sign-health
hstg=$tmp/hstaging; mkdir -p "$hstg/core/os/x86_64"
# unlocked ($gpgr has no passphrase) and staging empty -> silent
out=$(ARCHCI_R2_STAGING=$hstg ARCHCI_R2_RELEASE=$tmp/hx ARCHCI_RCLONE_CONFIG=/dev/null \
      ARCHCI_RELEASE_GNUPGHOME=$gpgr ARCHCI_RELEASE_KEY=archci-release ARCHCI_STAGING_WARN=2 "$health" 2>&1)
[[ -z $out ]] || fail "health must be silent when unlocked and staging empty: $out"
# unlocked but a backlog above the threshold -> WARNING
mkpkg "$hstg/core/os/x86_64" p1 1-1; mkpkg "$hstg/core/os/x86_64" p2 1-1
out=$(ARCHCI_R2_STAGING=$hstg ARCHCI_R2_RELEASE=$tmp/hx ARCHCI_RCLONE_CONFIG=/dev/null \
      ARCHCI_RELEASE_GNUPGHOME=$gpgr ARCHCI_RELEASE_KEY=archci-release ARCHCI_STAGING_WARN=2 "$health" 2>&1)
[[ $out == *"not draining"* ]] || fail "health must warn on staging backlog: $out"
# a locked key (passphrase set, agent cache cleared) with a backlog -> ALERT
gpgL=$tmp/gpg-locked; mkdir -p "$gpgL"; chmod 700 "$gpgL"
gpg --homedir "$gpgL" --batch --pinentry-mode loopback --passphrase pw --quick-generate-key 'archci-release <l@t>' ed25519 sign never 2>/dev/null
gpgconf --homedir "$gpgL" --kill gpg-agent 2>/dev/null || true
out=$(ARCHCI_R2_STAGING=$hstg ARCHCI_R2_RELEASE=$tmp/hx ARCHCI_RCLONE_CONFIG=/dev/null \
      ARCHCI_RELEASE_GNUPGHOME=$gpgL ARCHCI_RELEASE_KEY=archci-release ARCHCI_STAGING_WARN=2 "$health" 2>&1)
[[ $out == *"LOCKED"* ]] || fail "health must ALERT when the key is locked and staging has packages: $out"

echo "--- sign prune guard: keep release packages when the local db was not seeded"
pg=$tmp/prune-guard
mkdir -p "$pg/release/core/os/x86_64" "$pg/staging/core/os/x86_64" "$tmp/pg-signer"
# release already holds a package but NO database, so the seed-from-release fails
mkpkg "$pg/release/core/os/x86_64" survivor 1-1
: >"$pg/release/core/os/x86_64/survivor-1-1-x86_64.pkg.tar.zst.sig"
# a new, validly builder-signed package (trusted key $gpgb) is waiting in staging
mkpkg "$pg/staging/core/os/x86_64" newpkg 1-1
np=$pg/staging/core/os/x86_64/newpkg-1-1-x86_64.pkg.tar.zst
gpg --homedir "$gpgb" --batch --detach-sign -u archci-builder -o "$np.buildsig" "$np"
out=$(ARCHCI_R2_STAGING=$pg/staging ARCHCI_R2_RELEASE=$pg/release ARCHCI_RCLONE_CONFIG=/dev/null \
      ARCHCI_RELEASE_GNUPGHOME=$gpgr ARCHCI_RELEASE_KEY=archci-release ARCHCI_BUILDER_KEYRING=$gpgk \
      ARCHCI_SIGNER_HOME=$tmp/pg-signer "$here/../signer/archci-sign" 2>&1)
[[ $out == *"skipping prune"* ]] || fail "guard should skip prune when the db was not seeded: $out"
[[ -f $pg/release/core/os/x86_64/survivor-1-1-x86_64.pkg.tar.zst ]] || fail "prune guard must not delete the survivor"
[[ -f $pg/release/core/os/x86_64/newpkg-1-1-x86_64.pkg.tar.zst ]] || fail "the new package should still be released"

echo "--- status"
"$status" | head -5
"$status" --json | ruby -rjson -e 'j=JSON.parse(STDIN.read); abort "bad json" unless j["queue"]["pending"] == 0 && j["outstanding"] == {"updates"=>0, "backlog"=>2} && j["built"]["omarchy-x86_64"] == 1 && j["arches"] == ["x86_64"] && j["repo"] == "omarchy" && j["pkgbuilds"]["packages"] == 3'

echo "--- multi-arch: workers claim by arch, any packages are pooled for every arch"
export ARCHCI_ARCHES="x86_64 aarch64"   # any packages default to the first: x86_64
mkpkgbuild archlinux-keyring 20260901-1 any
commit_pkgs any
"$scan"
# x86_64: linux, libsigc++ (acl built); any: archlinux-keyring; aarch64: acl, linux, libsigc++
"$status" --json | ruby -rjson -e 'j=JSON.parse(STDIN.read); abort "outstanding #{j["outstanding"]}" unless j["outstanding"] == {"updates"=>0, "backlog"=>6}; abort "tracked #{j["tracked"]}" unless j["tracked"]["omarchy-aarch64"] == 3 && j["tracked"]["omarchy-any"] == 1 && j["any_arch"] == "x86_64"'
! "$job" claim worker-6 riscv64 2>/dev/null || fail "claim for an arch not in ARCHCI_ARCHES must fail"
[[ $("$next" aarch64) == "5 omarchy aarch64 acl "* ]] || fail "aarch64 backlog should start at acl: $("$next" aarch64)"
[[ $(ARCHCI_IGNOREARCH=0 "$next" aarch64) == "" ]] || fail "with ARCHCI_IGNOREARCH=0 only packages listing aarch64 are offered"
out=$("$job" claim arm-1 aarch64)
id=$(sed -n 's/^id=//p' <<<"$out")
[[ $id == 5-*-omarchy,acl,1:2.3.2-1,aarch64 ]] || fail "aarch64 job id: $id"
grep -q '^arch=aarch64$' <<<"$out" || fail "job arch"
[[ $("$next" aarch64) == "5 omarchy aarch64 libsigc++ "* ]] || fail "running aarch64 acl must not be offered again"
[[ $("$next" x86_64) == "5 omarchy x86_64 libsigc++ "* ]] || fail "an aarch64 build must not block x86_64: $("$next" x86_64)"
inc=$ARCHCI_HOME/incoming/$id
echo log >"$inc/build.log"; mkpkg "$inc" acl 1:2.3.2-1 x86_64
"$job" report "$id" success
[[ -f $ARCHCI_HOME/queue/failed/$id.job ]] || fail "an aarch64 job uploading an x86_64 package must fail"
"$job" retry "$id"
id=$(sed -n 's/^id=//p' < <("$job" claim arm-1 aarch64))
[[ $id == *,acl,*,aarch64 ]] || fail "retry should be claimed first: $id"
inc=$ARCHCI_HOME/incoming/$id
echo log >"$inc/build.log"; mkpkg "$inc" acl 1:2.3.2-1 aarch64
: >"$inc/acl-1:2.3.2-1-aarch64.pkg.tar.zst.buildsig"
"$job" report "$id" success
[[ -f $ARCHCI_HOME/queue/done/$id.job ]] || fail "aarch64 job not done"
[[ $(<"$ARCHCI_HOME/built/omarchy-aarch64/acl") == "1:2.3.2-1 $(pkgcommit acl)" ]] || fail "aarch64 built record"
[[ -f $ARCHCI_HOME/repo/omarchy/os/aarch64/acl-1:2.3.2-1-aarch64.pkg.tar.zst.buildsig ]] || fail "aarch64 package not pooled with its buildsig"
[[ ! -e $ARCHCI_HOME/repo/omarchy/os/x86_64/acl-1:2.3.2-1-aarch64.pkg.tar.zst ]] || fail "aarch64 package must not land in x86_64"
[[ -f $ARCHCI_HOME/logs/omarchy/acl/1:2.3.2-1/aarch64/attempt-1.log ]] || fail "aarch64 log path"
# the any package: offered only to x86_64 workers, pooled into every arch
! "$job" enqueue archlinux-keyring 0 2>/dev/null || fail "an any package must be enqueued with ARCH=any"
"$job" enqueue archlinux-keyring 0 any
! "$job" enqueue acl 0 any 2>/dev/null || fail "an x86_64 package must not be enqueued as any"
! "$job" enqueue acl 0 riscv64 2>/dev/null || fail "enqueue for an arch not enabled must fail"
id=$(sed -n 's/^id=//p' < <("$job" claim arm-2 aarch64))
[[ $id == *,libsigc++,*,aarch64 ]] || fail "an aarch64 worker must skip the pending any job: $id"
id=$(sed -n 's/^id=//p' < <("$job" claim worker-7 x86_64))
[[ $id == 0-*-omarchy,archlinux-keyring,20260901-1,any ]] || fail "x86_64 worker should get the any job: $id"
inc=$ARCHCI_HOME/incoming/$id
echo log >"$inc/build.log"; mkpkg "$inc" archlinux-keyring 20260901-1 any
: >"$inc/archlinux-keyring-20260901-1-any.pkg.tar.zst.buildsig"
"$job" report "$id" success
[[ -f $ARCHCI_HOME/queue/done/$id.job ]] || fail "any job not done"
[[ $(<"$ARCHCI_HOME/built/omarchy-any/archlinux-keyring") == "20260901-1 $(pkgcommit archlinux-keyring) x86_64,aarch64" ]] || fail "any built record: $(<"$ARCHCI_HOME/built/omarchy-any/archlinux-keyring")"
for a in x86_64 aarch64; do
	[[ -f $ARCHCI_HOME/repo/omarchy/os/$a/archlinux-keyring-20260901-1-any.pkg.tar.zst ]] || fail "any package not pooled for $a"
	[[ -f $ARCHCI_HOME/repo/omarchy/os/$a/archlinux-keyring-20260901-1-any.pkg.tar.zst.buildsig ]] || fail "any buildsig not pooled for $a"
done
[[ ! -e $inc ]] || fail "incoming not cleaned"
[[ $("$next" x86_64) != *archlinux-keyring* ]] || fail "built any package must not be outstanding"
# enabling another arch makes every any package outstanding again, so the new arch gets them
[[ $(ARCHCI_ARCHES="x86_64 aarch64 riscv64" "$next" x86_64) == *" any archlinux-keyring "* ]] || fail "an any package must be rebuilt for an arch enabled later: $(ARCHCI_ARCHES="x86_64 aarch64 riscv64" "$next" x86_64)"
"$status" --json | ruby -rjson -e 'j=JSON.parse(STDIN.read); abort "built #{j["built"]}" unless j["built"]["omarchy-any"] == 1 && j["built"]["omarchy-aarch64"] == 1 && j["built"]["omarchy-x86_64"] == 1'

echo "--- the PKGBUILD repository URL is config: a scan follows a changed one"
pkgs2=$tmp/pkgs2
git clone -q "$pkgs" "$pkgs2"
mkdir -p "$pkgs2/pkgbuilds/lib32-thing/.omarchy"
printf 'pkgname=lib32-thing\npkgver=1\npkgrel=1\narch=(x86_64)\n' >"$pkgs2/pkgbuilds/lib32-thing/PKGBUILD"
echo '{"source": "aur"}' >"$pkgs2/pkgbuilds/lib32-thing/.omarchy/package.json"
git -C "$pkgs2" add -A && git -C "$pkgs2" -c user.name=t -c user.email=t@t commit -qm fork
ARCHCI_PKGBUILDS_URL=file://$pkgs2 "$scan"
ARCHCI_PKGBUILDS_URL=file://$pkgs2 "$here/../master/archci-pkgs" lib32-thing | grep -q '^lib32-thing 1-1 [0-9a-f]* x86_64 multilib aur build -$' || fail "fork's package missing or wrong profile"

echo "--- claim order: the farm's own packages, then core, extra, multilib, local, aur"
pkgs3=$tmp/pkgs3
git clone -q "$pkgs" "$pkgs3"
mk3() { mkdir -p "$pkgs3/pkgbuilds/$1/.omarchy"; printf 'pkgname=%s\npkgver=1\npkgrel=1\narch=(x86_64)\n' "$1" >"$pkgs3/pkgbuilds/$1/PKGBUILD"; printf '%s\n' "$2" >"$pkgs3/pkgbuilds/$1/.omarchy/package.json"; }
mk3 zz-core   '{"source": "arch", "arch_repo": "core"}'
mk3 aa-extra  '{"source": "arch", "arch_repo": "extra"}'
mk3 mm-local  '{"source": "local"}'
mk3 bb-aur    '{"source": "aur"}'
mk3 lib32-mul '{"source": "arch", "arch_repo": "multilib"}'
mk3 archci    '{"source": "local"}'
git -C "$pkgs3" add -A && git -C "$pkgs3" -c user.name=t -c user.email=t@t commit -qm order
order=$(ARCHCI_HOME=$tmp/home3 ARCHCI_PKGBUILDS_URL=file://$pkgs3 ARCHCI_PKG_ALSO=archci bash -c '
	mkdir -p "$ARCHCI_HOME"/{queue/{pending,running,done,failed},built,lock}
	"'"$scan"'" >/dev/null 2>&1
	ruby -e "require %q{'"$here"'/../lib/archci}; puts Archci.outstanding(arch: %q{x86_64}).map { |e| e[%q{pkgbase}] }.join(%q{ })"')
# the clone's own arch packages (no arch_repo) sort after multilib and before local
[[ $order =~ ^archci\ zz-core\ aa-extra\ lib32-mul\ .*\ mm-local\ bb-aur$ ]] || fail "claim order wrong: $order"

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
echo "ALL OK"
