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
pk=$(mkpkg "$tmp" gate 1-1)
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
sub=""; pos=(); fmt=""; sep=""; list=/dev/null; ignore=
while [[ $# -gt 0 ]]; do
  case $1 in
    --format) fmt=$2; shift 2;;
    --separator) sep=$2; shift 2;;
    --files-from) list=$2; shift 2;;
    --transfers|--checkers|--config|--stats|--timeout|--contimeout) shift 2;;
    --ignore-existing) ignore=1; shift;;
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
  copy) if [[ $list == /dev/null && -d ${pos[0]} ]]; then   # recursive dir copy (archci-stage logs)
          (cd "${pos[0]}" && find . -type f -printf '%P\n') | while IFS= read -r f; do
            [[ -n $ignore && -f ${pos[1]}/$f ]] && continue
            mkdir -p "$(dirname "${pos[1]}/$f")"; cp "${pos[0]}/$f" "${pos[1]}/$f"; done
        else while IFS= read -r f; do [[ -f ${pos[0]}/$f ]] || continue; mkdir -p "$(dirname "${pos[1]}/$f")"; cp "${pos[0]}/$f" "${pos[1]}/$f"; done <"$list"; fi;;
  delete) while IFS= read -r f; do rm -f "${pos[0]}/$f"; done <"$list";;
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
hp=$(mkpkg "$ARCHCI_HOME/repo/omarchy/os/x86_64" hello 1-1); hn=${hp##*/}
gpg --homedir "$gpgb" --batch --detach-sign -u archci-builder -o "$hp.buildsig" "$hp"
# an untrusted package (signed by the attacker key) also lands in the pool
ep=$(mkpkg "$ARCHCI_HOME/repo/omarchy/os/x86_64" evil 1-1); en=${ep##*/}
gpg --homedir "$gpgx" --batch --detach-sign -u evil -o "$ep.buildsig" "$ep"

# a makepkg log a build sent (the build log itself is the journal's), in the
# archive tree; stage copies it to R2 and keeps the local file
logdir=$ARCHCI_HOME/logs/omarchy/hello/1-1/x86_64
mkdir -p "$logdir"; printf 'building hello\n==> done\n' >"$logdir/attempt-1-hello-1-1-x86_64-build.log"
ARCHCI_R2_LOGS=$R2/logs "$master/archci-stage" --force
[[ ! -e $hp && ! -e $ep ]] || fail "stage must move packages out of the pool"
[[ -f $staging/omarchy/os/x86_64/$hn.buildsig ]] || fail "buildsig not staged"
[[ -f $R2/logs/omarchy/hello/1-1/x86_64/attempt-1-hello-1-1-x86_64-build.log ]] || fail "the makepkg log must be archived to R2"
[[ -f $logdir/attempt-1-hello-1-1-x86_64-build.log ]] || fail "stage must keep the local log (archive is a copy)"
# a log already in R2 is not re-uploaded (ignore-existing): change it locally,
# add a new one, restage; R2 keeps the old content and gains only the new file
printf 'CHANGED\n' >"$logdir/attempt-1-hello-1-1-x86_64-build.log"
printf 'second attempt\n' >"$logdir/attempt-2.log"
ARCHCI_R2_LOGS=$R2/logs "$master/archci-stage" --force
[[ -f $R2/logs/omarchy/hello/1-1/x86_64/attempt-2.log ]] || fail "a new log must be archived on the next stage"
[[ $(<"$R2/logs/omarchy/hello/1-1/x86_64/attempt-1-hello-1-1-x86_64-build.log") != CHANGED ]] || fail "an already-archived log must not be re-uploaded (--ignore-existing)"

"$sign"
# the trusted package is released and signed; the attacker package is rejected
rel=$release/omarchy/os/x86_64
[[ -f $rel/$hn && -f $rel/$hn.sig ]] || fail "trusted package not released+signed"
[[ ! -e $release/omarchy/os/x86_64/$en ]] || fail "attacker package must not be released"
[[ -f $rel/omarchy.db.tar.gz && -f $rel/omarchy.db ]] || fail "release database (both names) missing"
bsdtar -xOf "$rel/omarchy.db.tar.gz" '*/desc' | grep -xF "$hn" >/dev/null || fail "hello not in release db under its hashed name"
bsdtar -xOf "$rel/omarchy.db.tar.gz" '*/desc' | grep -A1 -x '%SHA256SUM%' | grep -qxF "${hn: -76:64}" || fail "the db's SHA256SUM is the hash in the name"
gpg --homedir "$relpub" --batch --verify "$rel/$hn.sig" "$rel/$hn" 2>/dev/null || fail "released signature must verify for clients"
# staging is drained (both the released and the rejected package removed)
[[ -z $(find "$staging" -name '*.pkg.tar.zst' 2>/dev/null) ]] || fail "staging must be drained"

echo "--- a newer version prunes the one it replaces, from the database diff, the pass it lands"
mkdir -p "$ARCHCI_HOME/repo/omarchy/os/x86_64"; hp2=$(mkpkg "$ARCHCI_HOME/repo/omarchy/os/x86_64" hello 1-2); hn2=${hp2##*/}
gpg --homedir "$gpgb" --batch --detach-sign -u archci-builder -o "$hp2.buildsig" "$hp2"
"$master/archci-stage" --force
out=$("$here/../signer/archci-sign" 2>&1)
[[ $out == *"pruning 1 superseded package(s) from [omarchy]"* ]] || fail "the replaced version must be pruned by the diff: $out"
[[ -f $rel/$hn2.sig && ! -e $rel/$hn && ! -e $rel/$hn.sig ]] || fail "hello 1-1 and its signature must be gone, 1-2 released: $(ls "$rel")"
[[ -f $ARCHCI_SIGNER_HOME/prune-omarchy-os-x86_64.stamp ]] || fail "the listing prune leaves a stamp"

echo "--- a source package (os/src): released with its .sig, no database, the older version pruned"
mkdir -p "$ARCHCI_HOME/repo/omarchy/os/src"
# hello 1-1 an older sourcer's (unhashed .gz), hello 1-2 the current one's (hashed .zst)
sp1=$ARCHCI_HOME/repo/omarchy/os/src/hello-1-1.src.tar.gz; echo "sources 1-1" | gzip >"$sp1"
gpg --homedir "$gpgb" --batch --detach-sign -u archci-builder -o "$sp1.buildsig" "$sp1"
echo "sources 1-2" | zstd -q >"$tmp/s12"; sp2=$ARCHCI_HOME/repo/omarchy/os/src/hello-1-2-$(sha256sum "$tmp/s12" | cut -c1-64).src.tar.zst; mv "$tmp/s12" "$sp2"; sn2=${sp2##*/}
gpg --homedir "$gpgb" --batch --detach-sign -u archci-builder -o "$sp2.buildsig" "$sp2"
echo "other" | zstd -q >"$tmp/hw"; hw=$ARCHCI_HOME/repo/omarchy/os/src/hello-world-2-1-$(sha256sum "$tmp/hw" | cut -c1-64).src.tar.zst; mv "$tmp/hw" "$hw"; hwn=${hw##*/}   # another package whose name starts the same way
gpg --homedir "$gpgb" --batch --detach-sign -u archci-builder -o "$hw.buildsig" "$hw"
"$master/archci-stage" --force
out=$("$sign" 2>&1)
srel=$release/omarchy/os/src
[[ -f $srel/$sn2 && -f $srel/$sn2.sig && -f $srel/$hwn.sig ]] || fail "source packages must be released with their signatures: $(ls "$srel")"
[[ ! -e $srel/hello-1-1.src.tar.gz && ! -e $srel/hello-1-1.src.tar.gz.sig ]] || fail "the older source package must be pruned: $(ls "$srel")"
[[ $out == *"pruning superseded omarchy/os/src/hello-1-1.src.tar.gz"* ]] || fail "the prune must be logged: $out"
! compgen -G "$srel/*.db*" >/dev/null || fail "os/src gets no database"
gpg --homedir "$relpub" --batch --verify "$srel/$sn2.sig" "$srel/$sn2" 2>/dev/null || fail "a source package's release signature must verify"
[[ -z $(find "$staging" -name '*.src.tar.*' 2>/dev/null) ]] || fail "staging must be drained of source packages"

echo "--- a pass takes ARCHCI_SIGN_BATCH packages, the farm's own first, the rest wait"
bs=$tmp/batch; mkdir -p "$bs/staging/omarchy/os/x86_64" "$bs/release/omarchy/os/x86_64" "$tmp/bs-signer"
declare -A bn=()   # name -> the hashed file name
for n in zzz-late archci-master aaa-early; do
	f=$(mkpkg "$bs/staging/omarchy/os/x86_64" $n 1-1); bn[$n]=${f##*/}
	gpg --homedir "$gpgb" --batch --detach-sign -u archci-builder -o "$f.buildsig" "$f"
done
touch -d '-2 hours' "$bs/staging/omarchy/os/x86_64/${bn[zzz-late]}"   # the oldest, but archci comes first
out=$(ARCHCI_R2_STAGING=$bs/staging ARCHCI_R2_RELEASE=$bs/release ARCHCI_SIGNER_HOME=$tmp/bs-signer ARCHCI_SIGN_BATCH=2 "$sign" 2>&1)
[[ $out == *"this pass takes 2"* && $out == *"signed 2, rejected 0; 1 left"* ]] || fail "batch of 2 out of 3: $out"
[[ -f $bs/release/omarchy/os/x86_64/${bn[archci-master]}.sig ]] || fail "the farm's own package must be in the first pass"
[[ -f $bs/release/omarchy/os/x86_64/${bn[zzz-late]}.sig ]] || fail "then the oldest"
[[ ! -e $bs/release/omarchy/os/x86_64/${bn[aaa-early]} && -f $bs/staging/omarchy/os/x86_64/${bn[aaa-early]} ]] || fail "the third waits in staging"
[[ ! -e $bs/staging/omarchy/os/x86_64/${bn[archci-master]}.buildsig ]] || fail "signed packages leave staging with their buildsig"
out=$(ARCHCI_R2_STAGING=$bs/staging ARCHCI_R2_RELEASE=$bs/release ARCHCI_SIGNER_HOME=$tmp/bs-signer ARCHCI_SIGN_BATCH=2 "$sign" 2>&1)
[[ $out == *"signed 1, rejected 0; 0 left"* ]] || fail "the next pass drains the rest: $out"
bsdtar -xOf "$bs/release/omarchy/os/x86_64/omarchy.db.tar.gz" '*/desc' | grep -c '\.pkg\.tar\.zst$' | grep -x 3 >/dev/null || fail "all three in the release db"

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
sv=$(mkpkg "$pg/release/core/os/x86_64" survivor 1-1)
: >"$sv.sig"
# a new, validly builder-signed package (trusted key $gpgb) is waiting in staging
np=$(mkpkg "$pg/staging/core/os/x86_64" newpkg 1-1)
gpg --homedir "$gpgb" --batch --detach-sign -u archci-builder -o "$np.buildsig" "$np"
out=$(ARCHCI_R2_STAGING=$pg/staging ARCHCI_R2_RELEASE=$pg/release ARCHCI_SIGNER_HOME=$tmp/pg-signer "$sign" 2>&1)
[[ $out == *"skipping prune"* ]] || fail "guard should skip prune when the db was not seeded: $out"
[[ -f $sv ]] || fail "prune guard must not delete the survivor"
[[ -f $pg/release/core/os/x86_64/${np##*/} ]] || fail "the new package should still be released"
echo "ALL OK"
