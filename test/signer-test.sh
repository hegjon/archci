#!/bin/bash
# signer-test.sh -- the two-stage signing gate with real gpg keys (builder
# signatures the signer trusts, release signatures clients verify), and the
# pipeline around it: the signer pulls what waits from the master's pool over
# ssh (a fake ssh into archci-shell signer, real rsync + rrsync), verifies,
# rejects, signs and returns the signatures; archci-publish verifies them with
# the release public key, indexes the databases, publishes to a local rclone
# stand-in, prunes, and empties the pool; archci-sign-health; the reconcile
# guard.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
source "$here/fixture.sh"
sign=$here/../signer/archci-sign
health=$here/../signer/archci-sign-health
publish=$master/archci-publish
unsigned=$master/archci-unsigned
for tool in rrsync rsync gpg repo-add vercmp; do command -v $tool >/dev/null || { echo "skip: $tool missing"; exit 0; }; done

echo "--- signing gate: two-stage builder + release signatures (real gpg)"
gpgb=$tmp/gpg-builder gpgk=$tmp/gpg-keyring gpgr=$tmp/gpg-release gpgx=$tmp/gpg-attacker relpub=$tmp/gpg-relpub
for h in "$gpgb" "$gpgk" "$gpgr" "$gpgx" "$relpub"; do mkdir -p "$h"; chmod 700 "$h"; done
gpg --homedir "$gpgb" --batch --pinentry-mode loopback --passphrase '' --quick-generate-key 'archci-builder <b@t>' ed25519 sign never 2>/dev/null
gpg --homedir "$gpgr" --batch --pinentry-mode loopback --passphrase '' --quick-generate-key 'archci-release <r@t>' ed25519 sign never 2>/dev/null
gpg --homedir "$gpgx" --batch --pinentry-mode loopback --passphrase '' --quick-generate-key 'evil <e@t>' ed25519 sign never 2>/dev/null
gpg --homedir "$gpgb" --armor --export b@t | gpg --homedir "$gpgk" --batch --import 2>/dev/null   # trust only the real builder
gpg --homedir "$gpgr" --armor --export r@t >"$tmp/release.pub"
gpg --homedir "$relpub" --batch --import "$tmp/release.pub" 2>/dev/null
pk=$(mkpkg "$tmp" gate 1-1)
gpg --homedir "$gpgb" --batch --detach-sign -u archci-builder -o "$pk.buildsig" "$pk"
gpg --homedir "$gpgk" --batch --verify "$pk.buildsig" "$pk" 2>/dev/null || fail "authorized builder signature must verify"
gpg --homedir "$gpgx" --batch --detach-sign -u evil -o "$tmp/evil.buildsig" "$pk"
! gpg --homedir "$gpgk" --batch --verify "$tmp/evil.buildsig" "$pk" 2>/dev/null || fail "unknown builder key must be rejected"
gpg --homedir "$gpgr" --batch --pinentry-mode loopback --detach-sign -u archci-release -o "$pk.sig" "$pk"
gpg --homedir "$relpub" --batch --verify "$pk.sig" "$pk" 2>/dev/null || fail "release signature must verify for clients"
printf tamper >>"$pk"
! gpg --homedir "$relpub" --batch --verify "$pk.sig" "$pk" 2>/dev/null || fail "tampered package must fail release verification"

# --- the fakes: ssh into archci-shell signer, rclone as local paths ----------
mkdir -p "$tmp/bin"
cat >"$tmp/bin/ssh" <<'SH'
#!/bin/bash
[[ -e $TESTTMP/master-down ]] && exit 255
while [[ $1 == -* ]]; do case $1 in -i|-o|-l|-p) shift 2;; *) shift;; esac; done
shift   # the host
SSH_ORIGINAL_COMMAND="$*" exec "$ARCHCI_SHELL" signer
SH
cat >"$tmp/bin/rclone" <<'SH'
#!/bin/bash
sub=""; pos=(); list=/dev/null
while [[ $# -gt 0 ]]; do
  case $1 in
    --files-from) list=$2; shift 2;;
    --header-upload|--transfers|--checkers|--config|--format|--separator|--include|--exclude) shift 2;;
    --*) shift;;
    *) [[ -z $sub ]] && sub=$1 || pos+=("$1"); shift;;
  esac
done
case $sub in
  lsf) [[ -d ${pos[0]} ]] && (cd "${pos[0]}" && find . -maxdepth 1 -type f -printf '%P\n');;
  copyto) [[ -f ${pos[0]} ]] || exit 1; mkdir -p "$(dirname "${pos[1]}")"; cp "${pos[0]}" "${pos[1]}";;
  deletefile) rm -f "${pos[0]}";;
  copy) [[ -e $TESTTMP/rclone.fail ]] && { echo "rclone: the bucket is down (test)" >&2; exit 1; }
        while IFS= read -r f; do [[ -f ${pos[0]}/$f ]] || continue; mkdir -p "$(dirname "${pos[1]}/$f")"; cp "${pos[0]}/$f" "${pos[1]}/$f"; done <"$list";;
  delete) while IFS= read -r f; do rm -f "${pos[0]}/$f"; done <"$list";;
  move) [[ -d ${pos[0]} ]] && (cd "${pos[0]}" && find . -type f -printf '%P\n') | while IFS= read -r f; do [[ -f ${pos[1]}/$f ]] && continue; mkdir -p "$(dirname "${pos[1]}/$f")"; mv "${pos[0]}/$f" "${pos[1]}/$f"; done;;
esac
exit 0
SH
chmod +x "$tmp/bin/ssh" "$tmp/bin/rclone"; export PATH="$tmp/bin:$PATH" TESTTMP=$tmp
export ARCHCI_SHELL=$master/archci-shell ARCHCI_MASTER=archci@master ARCHCI_SIGNER_KEY=$tmp/signer_key
: >"$ARCHCI_SIGNER_KEY"
export ARCHCI_RELEASE_GNUPGHOME=$gpgr ARCHCI_RELEASE_KEY=archci-release ARCHCI_BUILDER_KEYRING=$gpgk ARCHCI_SIGNER_HOME=$tmp/signer
export ARCHCI_RELEASE_PUBKEY=$tmp/release.pub ARCHCI_RCLONE_CONFIG=/dev/null ARCHCI_ARCHES="x86_64 aarch64" ARCHCI_SIGN_BATCH=20
release=$tmp/r2; export ARCHCI_R2_RELEASE=$release
mkdir -p "$ARCHCI_SIGNER_HOME" "$ARCHCI_HOME"/{sigs,db,released}
pool=$ARCHCI_HOME/repo
bsig() { gpg --homedir "$1" --batch --detach-sign -u "$2" -o "$3.buildsig" "$3"; }
# pooled like a worker's upload: hello (trusted builder), evil (the attacker's
# key), an any package in both arch dirs, a source package
mkdir -p "$pool/omarchy/os/x86_64" "$pool/omarchy/os/aarch64" "$pool/omarchy/os/src"
hp=$(mkpkg "$pool/omarchy/os/x86_64" hello 1-1); hn=${hp##*/}; bsig "$gpgb" archci-builder "$hp"
ep=$(mkpkg "$pool/omarchy/os/x86_64" evil 1-1); en=${ep##*/}; bsig "$gpgx" evil "$ep"
ap=$(mkpkg "$pool/omarchy/os/x86_64" archlinux-keyring 1-1 any); an=${ap##*/}; bsig "$gpgb" archci-builder "$ap"
cp "$ap" "$ap.buildsig" "$pool/omarchy/os/aarch64/"
echo "sources 1-1" | zstd -q >"$tmp/s"; sp=$pool/omarchy/os/src/hello-1-1-$(sha256sum "$tmp/s" | cut -c1-64).src.tar.zst; mv "$tmp/s" "$sp"; sn=${sp##*/}; bsig "$gpgb" archci-builder "$sp"
touch -d '-1 hour' "$hp"   # the oldest

echo "--- a fresh farm: the first pass makes and publishes an empty database per arch, so workers' chroots can sync the repo"
out=$(ARCHCI_REPO=omarchy ARCHCI_ARCHES="x86_64 aarch64" "$publish" --force 2>&1)
[[ $out == *"made an empty database for [omarchy] x86_64"* && $out == *"[omarchy] aarch64"* ]] || fail "empty databases made: $out"
for a in x86_64 aarch64; do
	[[ -f $ARCHCI_HOME/db/omarchy/os/$a/omarchy.db.tar.gz && -L $ARCHCI_HOME/db/omarchy/os/$a/omarchy.db ]] || fail "the database and its .db name for $a"
	[[ -f $release/omarchy/os/$a/omarchy.db.tar.gz && -f $release/omarchy/os/$a/omarchy.db ]] || fail "published for $a: $(find "$release" -name '*.db*')"
	[[ -z $(bsdtar -tf "$release/omarchy/os/$a/omarchy.db.tar.gz") ]] || fail "empty"
done
[[ -f $ARCHCI_HOME/released/omarchy-x86_64 && ! -s $ARCHCI_HOME/released/omarchy-x86_64 ]] || fail "an empty listing, so a claim does not fall back to the lag rule"
out=$(ARCHCI_REPO=omarchy ARCHCI_ARCHES="x86_64 aarch64" "$publish" --force 2>&1)
[[ $out != *"made an empty database"* ]] || fail "made once"

echo "--- archci unsigned: what waits, the oldest first, an any package once, a limit"
mapfile -t u < <("$unsigned" 0)
[[ ${#u[@]} == 4 && ${u[0]} == omarchy/os/x86_64/$hn ]] || fail "unsigned must list the 4 files, hello (oldest) first: ${u[*]}"
(( $(printf '%s\n' "${u[@]}" | grep -c "$an") == 1 )) || fail "an any package is listed once: ${u[*]}"
[[ $("$unsigned" 2 | wc -l) == 2 ]] || fail "unsigned N limits"

echo "--- archci-sign: pulls over ssh, verifies, rejects the attacker's, signs, returns the signatures"
out=$("$sign" 2>&1) || fail "archci-sign failed: $out"
[[ $out == *"signed 3, rejected 1"* ]] || fail "3 signed, 1 rejected: $out"
[[ -f $ARCHCI_HOME/sigs/omarchy/os/x86_64/$hn.sig && -f $ARCHCI_HOME/sigs/omarchy/os/src/$sn.sig ]] || fail "signatures must land in sigs/: $(find "$ARCHCI_HOME/sigs" -type f)"
{ [[ -f $ep.rejected ]] && grep -q "builder signature invalid" "$ep.rejected"; } || fail "the rejected file is marked with the reason: $(cat "$ep.rejected" 2>/dev/null)"
[[ -e $ARCHCI_HOME/publish.needed ]] || fail "the signer flags the publish"
! "$unsigned" 0 | grep -q "$en" || fail "a rejected file is not offered again"
[[ $("$unsigned" 0 | wc -l) == 0 ]] || fail "signed and waiting for the publish, or rejected: nothing is offered again: $("$unsigned" 0)"
gpg --homedir "$relpub" --batch --verify "$ARCHCI_HOME/sigs/omarchy/os/x86_64/$hn.sig" "$hp" 2>/dev/null || fail "the returned signature is the release key's"
# a signature from the wrong key, planted in sigs/: dropped by the publish
gpg --homedir "$gpgx" --batch --detach-sign -u evil -o "$ARCHCI_HOME/sigs/omarchy/os/x86_64/$en.sig" "$ep"

echo "--- archci-publish: accepts, indexes, publishes, prunes, empties the pool"
out=$("$publish" 2>&1) || fail "archci-publish failed: $out"
[[ $out == *"accepted 3 release signature(s)"* && $out == *"REJECT $en.sig"* ]] || fail "3 accepted, the planted one rejected: $out"
[[ $out == *"indexed 2 package(s) into [omarchy] x86_64"* && $out == *"indexed 1 package(s) into [omarchy] aarch64"* ]] || fail "hello + keyring into x86_64, keyring into aarch64: $out"
db=$ARCHCI_HOME/db/omarchy/os/x86_64/omarchy.db.tar.gz
bsdtar -xOf "$db" '*/desc' | grep -qxF "$hn" || fail "hello in the x86_64 db under its hashed name"
bsdtar -xOf "$ARCHCI_HOME/db/omarchy/os/aarch64/omarchy.db.tar.gz" '*/desc' | grep -qxF "$an" || fail "the any package in the aarch64 db"
! bsdtar -xOf "$db" '*/desc' | grep -qxF "$en" || fail "evil must not be indexed"
{ grep -qx "hello 1-1" "$ARCHCI_HOME/released/omarchy-x86_64" && grep -qx "archlinux-keyring 1-1" "$ARCHCI_HOME/released/omarchy-aarch64"; } || fail "the released listings come from the databases: $(cat "$ARCHCI_HOME"/released/*)"
grep -qxF "$sn" "$ARCHCI_HOME/released/omarchy-src" || fail "the signed source package is listed as released"
rel=$release/omarchy/os/x86_64
[[ -f $rel/$hn && -f $rel/$hn.sig && -f $rel/omarchy.db.tar.gz && -f $rel/omarchy.db && -f $rel/omarchy.files ]] || fail "package, signature and database (both names) published: $(ls "$rel")"
[[ -f $rel/$an && -f $rel/$an.sig && -f $release/omarchy/os/aarch64/$an && -f $release/omarchy/os/aarch64/$an.sig ]] || fail "the any package in both arch dirs (uploaded once, copied): $(ls "$rel" "$release/omarchy/os/aarch64")"
[[ -f $release/omarchy/os/src/$sn && -f $release/omarchy/os/src/$sn.sig ]] || fail "the source package and its signature published"
{ [[ -f $release/release.pub ]] && cmp -s "$release/release.pub" "$tmp/release.pub"; } || fail "release.pub published"
[[ ! -e $release/omarchy/os/x86_64/$en ]] || fail "evil must not be published"
gpg --homedir "$relpub" --batch --verify "$rel/$hn.sig" "$rel/$hn" 2>/dev/null || fail "the published signature verifies for clients"
bsdtar -xOf "$rel/omarchy.db.tar.gz" '*/desc' | grep -A1 -x '%SHA256SUM%' | grep -qxF "${hn: -76:64}" || fail "the db's SHA256SUM is the hash in the name"
[[ ! -e $hp && ! -e $hp.sig && ! -e $hp.buildsig && ! -e $sp && ! -e $pool/omarchy/os/aarch64/$an ]] || fail "published files leave the pool with their .buildsig: $(find "$pool" -type f)"
[[ -f $ep && -f $ep.rejected ]] || fail "the rejected file stays in the pool, marked"
[[ $("$unsigned" 0 | wc -l) == 0 ]] || fail "nothing waits now: $("$unsigned" 0)"
[[ -z $(find "$ARCHCI_HOME/sigs" -type f) ]] || fail "sigs/ is drained"

echo "--- a newer version replaces the old in the database and the release, a newer source package prunes the older"
mkdir -p "$pool/omarchy/os/x86_64" "$pool/omarchy/os/src"   # the publish removed the emptied directories
hp2=$(mkpkg "$pool/omarchy/os/x86_64" hello 1-2); hn2=${hp2##*/}; bsig "$gpgb" archci-builder "$hp2"
echo "sources 1-2" | zstd -q >"$tmp/s"; sp2=$pool/omarchy/os/src/hello-1-2-$(sha256sum "$tmp/s" | cut -c1-64).src.tar.zst; mv "$tmp/s" "$sp2"; sn2=${sp2##*/}; bsig "$gpgb" archci-builder "$sp2"
echo "other" | zstd -q >"$tmp/s"; hw=$pool/omarchy/os/src/hello-world-2-1-$(sha256sum "$tmp/s" | cut -c1-64).src.tar.zst; mv "$tmp/s" "$hw"; hwn=${hw##*/}; bsig "$gpgb" archci-builder "$hw"   # a name that starts the same way
"$sign" >/dev/null 2>&1; out=$("$publish" 2>&1)
[[ $out == *"pruning 2 superseded file(s)"* ]] || fail "hello 1-1 and its source package are pruned by the database diff and the version compare: $out"
[[ -f $rel/$hn2.sig && ! -e $rel/$hn && ! -e $rel/$hn.sig ]] || fail "hello 1-1 and its signature gone, 1-2 released: $(ls "$rel")"
[[ -f $release/omarchy/os/src/$sn2.sig && -f $release/omarchy/os/src/$hwn.sig && ! -e $release/omarchy/os/src/$sn && ! -e $release/omarchy/os/src/$sn.sig ]] || fail "the older source package pruned, hello-world kept: $(ls "$release/omarchy/os/src")"
bsdtar -xOf "$db" '*/desc' | grep -c '\.pkg\.tar\.zst$' | grep -qx 2 || fail "the x86_64 db names hello 1-2 and the keyring, nothing else"
{ grep -qx "hello 1-2" "$ARCHCI_HOME/released/omarchy-x86_64" && ! grep -qx "hello 1-1" "$ARCHCI_HOME/released/omarchy-x86_64"; } || fail "the listing follows the database"

echo "--- two versions signed in one pass: repo-add -R keeps the newer, the older leaves the pool whole, never published"
mkdir -p "$pool/omarchy/os/x86_64"
o1=$(mkpkg "$pool/omarchy/os/x86_64" twice 1-1); bsig "$gpgb" archci-builder "$o1"; touch -d '-1 minute' "$o1"
o2=$(mkpkg "$pool/omarchy/os/x86_64" twice 1-2); bsig "$gpgb" archci-builder "$o2"
"$sign" >/dev/null 2>&1; "$publish" >/dev/null 2>&1
[[ ! -e $o1 && ! -e $o1.sig && ! -e $o1.buildsig && ! -e $rel/${o1##*/} && -f $rel/${o2##*/}.sig ]] || fail "only 1-2 is published; 1-1, its signatures included, is gone from the pool and never reached the release: $(ls "$pool/omarchy/os/x86_64" "$rel")"
echo "--- an older version arriving after a newer was published never downgrades the release"
mkdir -p "$pool/omarchy/os/x86_64"
o0=$(mkpkg "$pool/omarchy/os/x86_64" twice 1-0); bsig "$gpgb" archci-builder "$o0"
"$sign" >/dev/null 2>&1; out=$("$publish" 2>&1)
[[ $out == *"${o0##*/}: older than the database's version"* ]] || fail "the stale build is refused: $out"
{ bsdtar -xOf "$db" '*/desc' | grep -qxF "${o2##*/}" && ! bsdtar -xOf "$db" '*/desc' | grep -qxF "${o0##*/}"; } || fail "the database keeps 1-2"
[[ ! -e $o0 && ! -e $o0.sig && ! -e $o0.buildsig && ! -e $rel/${o0##*/} && -f $rel/${o2##*/} ]] || fail "1-0 leaves the pool and never reaches the release: $(ls "$pool/omarchy/os/x86_64" "$rel")"

echo "--- a pass takes ARCHCI_SIGN_BATCH files, the farm's own first, then the oldest"
mkdir -p "$pool/omarchy/os/x86_64"
for n in zzz-late archci-master aaa-early; do f=$(mkpkg "$pool/omarchy/os/x86_64" $n 1-1); bsig "$gpgb" archci-builder "$f"; declare "bn_${n//-/_}=${f##*/}"; done
touch -d '-2 hours' "$pool/omarchy/os/x86_64/$bn_zzz_late"   # the oldest, but archci comes first
mapfile -t order < <("$unsigned" 0)
[[ ${order[0]} == */$bn_archci_master && ${order[1]} == */$bn_zzz_late && ${order[2]} == */$bn_aaa_early ]] || fail "the farm's own first, then the oldest: ${order[*]}"
out=$(ARCHCI_SIGN_BATCH=2 "$sign" 2>&1)
[[ $out == *"has 2 file(s) to sign"* && $out == *"signed 2, rejected 0"* ]] || fail "a batch of 2 of 3: $out"
[[ -f $ARCHCI_HOME/sigs/omarchy/os/x86_64/$bn_archci_master.sig && -f $ARCHCI_HOME/sigs/omarchy/os/x86_64/$bn_zzz_late.sig && ! -e $ARCHCI_HOME/sigs/omarchy/os/x86_64/$bn_aaa_early.sig ]] || fail "the third waits: $(ls "$ARCHCI_HOME/sigs/omarchy/os/x86_64")"
out=$(ARCHCI_SIGN_BATCH=2 "$sign" 2>&1)
[[ $out == *"signed 1, rejected 0"* ]] || fail "the next pass takes the rest: $out"
"$publish" >/dev/null 2>&1
bsdtar -xOf "$db" '*/desc' | grep -c '\.pkg\.tar\.zst$' | grep -qx 6 || fail "all three joined hello, the keyring and twice in the db"

echo "--- sign-health: quiet when healthy, warns on a backlog, a locked key, an unreachable master"
mkdir -p "$pool/omarchy/os/x86_64"
out=$(ARCHCI_UNSIGNED_WARN=2 "$health" 2>&1)
[[ -z $out ]] || fail "silent when unlocked and nothing waits: $out"
for n in p1 p2; do f=$(mkpkg "$pool/omarchy/os/x86_64" $n 1-1); bsig "$gpgb" archci-builder "$f"; done
out=$(ARCHCI_UNSIGNED_WARN=2 "$health" 2>&1)
[[ $out == *"2 file(s) wait unsigned"*"not draining"* ]] || fail "warns on a backlog: $out"
gpgL=$tmp/gpg-locked; mkdir -p "$gpgL"; chmod 700 "$gpgL"
gpg --homedir "$gpgL" --batch --pinentry-mode loopback --passphrase pw --quick-generate-key 'archci-release <l@t>' ed25519 sign never 2>/dev/null
gpgconf --homedir "$gpgL" --kill gpg-agent 2>/dev/null || true
out=$(ARCHCI_RELEASE_GNUPGHOME=$gpgL ARCHCI_UNSIGNED_WARN=2 "$health" 2>&1)
[[ $out == *"LOCKED"* ]] || fail "ALERT when the key is locked and files wait: $out"
out=$(ARCHCI_RELEASE_GNUPGHOME=$gpgL "$sign" 2>&1); [[ $out == *"release key is locked"* && $out == *"signed 0"* ]] || fail "archci-sign stops at a locked key: $out"
touch "$tmp/master-down"
out=$(ARCHCI_UNSIGNED_WARN=2 "$health" 2>&1); [[ $out == *"cannot reach the master"* ]] || fail "warns when the master is unreachable: $out"
! "$sign" >/dev/null 2>&1 || fail "archci-sign fails when the master is unreachable"
rm -f "$tmp/master-down"
"$sign" >/dev/null 2>&1; "$publish" >/dev/null 2>&1

echo "--- the exported logs go to the release as <repo>/log/..., and leave logs/"
lg=$ARCHCI_HOME/logs/omarchy/hello/1-2/x86_64; mkdir -p "$lg"
printf 'event: job\ndata: {}\n\n' | zstd -q >"$lg/hello-1-2-x86_64-1789000000-feedfacefeedfacefeedfacefeedface.sse.zst"
out=$("$publish" --force 2>&1)
[[ $out == *"published 1 build log(s)"* ]] || fail "the log is published: $out"
[[ -f $release/omarchy/log/hello/1-2/x86_64/hello-1-2-x86_64-1789000000-feedfacefeedfacefeedfacefeedface.sse.zst && ! -e $lg ]] || fail "the log sits beside the packages under log/, and is gone from logs/: $(find "$release/omarchy/log" "$ARCHCI_HOME/logs" 2>/dev/null)"

echo "--- the reconcile: a stray file in the release goes, never against an empty database"
: >"$rel/stray-1-1-x86_64-$(printf 'a%.0s' {1..64}).pkg.tar.zst"
mkdir -p "$release/core/os/x86_64"; : >"$release/core/os/x86_64/survivor-1-1-x86_64.pkg.tar.zst"
mkdir -p "$ARCHCI_HOME/db/core/os/x86_64"; : >"$ARCHCI_HOME/db/core/os/x86_64/core.db.tar.gz"   # an empty (unreadable) database
out=$("$publish" --force 2>&1)
[[ $out == *"reconcile: pruning 1 file(s) from omarchy/os/x86_64"* ]] || fail "the stray is pruned: $out"
[[ ! -e $rel/stray-1-1-x86_64-$(printf 'a%.0s' {1..64}).pkg.tar.zst ]] || fail "the stray must be gone"
[[ $out == *"skipping the reconcile of core/os/x86_64"* && -f $release/core/os/x86_64/survivor-1-1-x86_64.pkg.tar.zst ]] || fail "an empty database never empties its release directory: $out"

echo "--- the listings wait for the upload: a pass whose upload fails names nothing new (a claim would send the worker to a 404)"
lp=$(mkpkg "$pool/omarchy/os/x86_64" late 1-1); ln=${lp##*/}; bsig "$gpgb" archci-builder "$lp"
mkdir -p "$pool/omarchy/os/src"; mkdir -p "$pool/omarchy/os/src"; echo "sources late" | zstd -q >"$tmp/s"; lsp=$pool/omarchy/os/src/late-1-1-$(sha256sum "$tmp/s" | cut -c1-64).src.tar.zst; mv "$tmp/s" "$lsp"; lsn=${lsp##*/}; bsig "$gpgb" archci-builder "$lsp"
mkdir -p "$ARCHCI_HOME/sigs/omarchy/os/x86_64" "$ARCHCI_HOME/sigs/omarchy/os/src"
gpg --homedir "$gpgr" --batch --detach-sign -u archci-release -o "$ARCHCI_HOME/sigs/omarchy/os/x86_64/$ln.sig" "$lp"
gpg --homedir "$gpgr" --batch --detach-sign -u archci-release -o "$ARCHCI_HOME/sigs/omarchy/os/src/$lsn.sig" "$lsp"
touch "$ARCHCI_HOME/publish.needed" "$TESTTMP/rclone.fail"
out=$("$publish" 2>&1) && fail "a pass whose upload fails must fail: $out"
[[ $out == *"indexed 1 package(s) into [omarchy] x86_64"* ]] || fail "indexed before the upload: $out"
[[ -e $ARCHCI_HOME/publish.needed ]] || fail "the failed pass keeps its trigger"
! grep -qx "late 1-1" "$ARCHCI_HOME/released/omarchy-x86_64" || fail "not listed as released: the database is not up: $(cat "$ARCHCI_HOME/released/omarchy-x86_64")"
! grep -qxF "$lsn" "$ARCHCI_HOME/released/omarchy-src" || fail "the source package is not listed: it is not up"
[[ ! -e $release/omarchy/os/src/$lsn && -f $lsp && -f $lsp.sig ]] || fail "nothing uploaded, the pool keeps the signed files"
rm -f "$TESTTMP/rclone.fail"
out=$("$publish" 2>&1) || fail "the next pass publishes: $out"
{ grep -qx "late 1-1" "$ARCHCI_HOME/released/omarchy-x86_64" && grep -qxF "$lsn" "$ARCHCI_HOME/released/omarchy-src"; } || fail "listed once up: $(cat "$ARCHCI_HOME"/released/omarchy-x86_64 "$ARCHCI_HOME"/released/omarchy-src)"
[[ -f $rel/$ln && -f $release/omarchy/os/src/$lsn && ! -e $lp && ! -e $lsp ]] || fail "late published and out of the pool"
[[ ! -e $ARCHCI_HOME/publish.needed ]] || fail "the trigger is consumed"

echo "--- without ARCHCI_R2_RELEASE: index only, the pool keeps the signed files"
mkdir -p "$pool/omarchy/os/x86_64"
f=$(mkpkg "$pool/omarchy/os/x86_64" local-only 1-1); bsig "$gpgb" archci-builder "$f"
"$sign" >/dev/null 2>&1
out=$(ARCHCI_R2_RELEASE='' "$publish" 2>&1)
[[ $out == *"indexed 1 package(s)"* && $out == *"indexed, not published"* ]] || fail "index only: $out"
[[ -f $f && -f $f.sig && ! -e $release/omarchy/os/x86_64/${f##*/} ]] || fail "the signed file stays pooled, nothing published"
grep -qx "local-only 1-1" "$ARCHCI_HOME/released/omarchy-x86_64" || fail "indexed counts as released for the claim"
echo "ALL OK"
