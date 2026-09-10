#!/bin/bash
# signer-test.sh -- the two-stage signing gate with real gpg keys (builder
# signatures the signer trusts, release signatures clients verify), the R2
# hand-off through a local rclone stand-in (master stages, signer verifies,
# rejects, release-signs, publishes, drains), archci-sign-health and the
# prune guard.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
source "$here/fixture.sh"
sign=$here/../signer/archci-sign

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
sub=""; pos=(); fmt=""; sep=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --format) fmt=$2; shift 2;;
    --separator) sep=$2; shift 2;;
    --transfers|--checkers|--config|--stats|--timeout|--contimeout) shift 2;;
    -R|--*) shift;;
    *) [[ -z $sub ]] && sub=$1 || pos+=("$1"); shift;;
  esac
done
case $sub in
  lsf) if [[ -d ${pos[0]} ]]; then   # --format tp: "<modtime><sep><path>", as the signer orders by
         if [[ ${fmt:-p} == tp ]]; then (cd "${pos[0]}" && find . -type f -printf "%TY-%Tm-%Td %TH:%TM:%TS${sep:-;}%P\n")
         else (cd "${pos[0]}" && find . -type f -printf '%P\n'); fi; fi;;
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
# the trusted builder keyring ($gpgk) and release key ($gpgr) from above
export ARCHCI_RELEASE_GNUPGHOME=$gpgr ARCHCI_RELEASE_KEY=archci-release
export ARCHCI_BUILDER_KEYRING=$gpgk ARCHCI_SIGNER_HOME=$tmp/signer
mkdir -p "$ARCHCI_SIGNER_HOME"

# a good package (built + builder-signed by the trusted key) lands in the master pool
mkdir -p "$ARCHCI_HOME/repo/omarchy/os/x86_64"
mkpkg "$ARCHCI_HOME/repo/omarchy/os/x86_64" hello 1-1
hp=$ARCHCI_HOME/repo/omarchy/os/x86_64/hello-1-1-x86_64.pkg.tar.zst
gpg --homedir "$gpgb" --batch --detach-sign -u archci-builder -o "$hp.buildsig" "$hp"
# an untrusted package (signed by the attacker key) also lands in the pool
mkpkg "$ARCHCI_HOME/repo/omarchy/os/x86_64" evil 1-1
ep=$ARCHCI_HOME/repo/omarchy/os/x86_64/evil-1-1-x86_64.pkg.tar.zst
gpg --homedir "$gpgx" --batch --detach-sign -u evil -o "$ep.buildsig" "$ep"

"$master/archci-stage" --force
[[ ! -e $hp && ! -e $ep ]] || fail "stage must move packages out of the pool"
[[ -f $staging/omarchy/os/x86_64/hello-1-1-x86_64.pkg.tar.zst.buildsig ]] || fail "buildsig not staged"

"$sign"
# the trusted package is released and signed; the attacker package is rejected
rel=$release/omarchy/os/x86_64
[[ -f $rel/hello-1-1-x86_64.pkg.tar.zst && -f $rel/hello-1-1-x86_64.pkg.tar.zst.sig ]] || fail "trusted package not released+signed"
[[ ! -e $release/omarchy/os/x86_64/evil-1-1-x86_64.pkg.tar.zst ]] || fail "attacker package must not be released"
[[ -f $rel/omarchy.db.tar.gz && -f $rel/omarchy.db ]] || fail "release database (both names) missing"
bsdtar -xOf "$rel/omarchy.db.tar.gz" '*/desc' | grep -xF 'hello-1-1-x86_64.pkg.tar.zst' >/dev/null || fail "hello not in release db"
gpg --homedir "$relpub" --batch --verify "$rel/hello-1-1-x86_64.pkg.tar.zst.sig" "$rel/hello-1-1-x86_64.pkg.tar.zst" 2>/dev/null || fail "released signature must verify for clients"
# staging is drained (both the released and the rejected package removed)
[[ -z $(find "$staging" -name '*.pkg.tar.zst' 2>/dev/null) ]] || fail "staging must be drained"

echo "--- sign-health: quiet when healthy, warns on lock or backlog"
health=$here/../signer/archci-sign-health
hstg=$tmp/hstaging; mkdir -p "$hstg/core/os/x86_64"
# unlocked ($gpgr has no passphrase) and staging empty -> silent
out=$(ARCHCI_R2_STAGING=$hstg ARCHCI_R2_RELEASE=$tmp/hx ARCHCI_STAGING_WARN=2 "$health" 2>&1)
[[ -z $out ]] || fail "health must be silent when unlocked and staging empty: $out"
# unlocked but a backlog above the threshold -> WARNING
mkpkg "$hstg/core/os/x86_64" p1 1-1; mkpkg "$hstg/core/os/x86_64" p2 1-1
out=$(ARCHCI_R2_STAGING=$hstg ARCHCI_R2_RELEASE=$tmp/hx ARCHCI_STAGING_WARN=2 "$health" 2>&1)
[[ $out == *"not draining"* ]] || fail "health must warn on staging backlog: $out"
# a locked key (passphrase set, agent cache cleared) with a backlog -> ALERT
gpgL=$tmp/gpg-locked; mkdir -p "$gpgL"; chmod 700 "$gpgL"
gpg --homedir "$gpgL" --batch --pinentry-mode loopback --passphrase pw --quick-generate-key 'archci-release <l@t>' ed25519 sign never 2>/dev/null
gpgconf --homedir "$gpgL" --kill gpg-agent 2>/dev/null || true
out=$(ARCHCI_R2_STAGING=$hstg ARCHCI_R2_RELEASE=$tmp/hx ARCHCI_RELEASE_GNUPGHOME=$gpgL ARCHCI_STAGING_WARN=2 "$health" 2>&1)
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
out=$(ARCHCI_R2_STAGING=$pg/staging ARCHCI_R2_RELEASE=$pg/release ARCHCI_SIGNER_HOME=$tmp/pg-signer "$sign" 2>&1)
[[ $out == *"skipping prune"* ]] || fail "guard should skip prune when the db was not seeded: $out"
[[ -f $pg/release/core/os/x86_64/survivor-1-1-x86_64.pkg.tar.zst ]] || fail "prune guard must not delete the survivor"
[[ -f $pg/release/core/os/x86_64/newpkg-1-1-x86_64.pkg.tar.zst ]] || fail "the new package should still be released"
echo "ALL OK"
