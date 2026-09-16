#!/bin/bash
# pool-test.sh -- archci_pool: how a worker's uploaded packages land in the
# master's pool. Runs without network or root on a throwaway ARCHCI_HOME.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export ARCHCI_CONF=/dev/null ARCHCI_HOME=$tmp/home ARCHCI_ARCHES="x86_64 aarch64" ARCHCI_ANY_ARCH=x86_64 JOURNAL_STREAM=1
source "$here/../lib/archci-common.sh"
mkdir -p "$ARCHCI_HOME/lock"
fail() { echo "FAIL: $*" >&2; exit 1; }
pool=$ARCHCI_HOME/repo
# up NAME-VERSION-ARCH... -- an upload of real (smallest possible) packages,
# named as a worker names them (with the sha256) unless UNHASHED=1
mkpkg() {   # DIR NAME VERSION ARCH -> the file, as archci-build would name it
	local d=$tmp/mkpkg f=$1/$2-$3-$4.pkg.tar.zst sha; rm -rf "$d"; mkdir -p "$d"
	printf 'pkgname = %s\npkgbase = %s\npkgver = %s\npkgdesc = fake\nurl = x\nbuilddate = 1\npackager = t\nsize = 0\narch = %s\n' \
		"$2" "${2%-debug}" "$3" "$4" >"$d/.PKGINFO"
	bsdtar -C "$d" -cf - .PKGINFO | zstd -q >"$f"
	if [[ ${UNHASHED:-0} == 1 ]]; then printf '%s\n' "$f"; return; fi
	sha=$(sha256sum "$f"); mv "$f" "${f%.pkg.tar.zst}-${sha%% *}.pkg.tar.zst"; printf '%s\n' "${f%.pkg.tar.zst}-${sha%% *}.pkg.tar.zst"
}
up() {
	rm -rf "$tmp/inc"; mkdir -p "$tmp/inc"; local s stem arch
	for s in "$@"; do stem=${s%.pkg.tar.zst}; arch=${stem##*-}; stem=${stem%-*}; mkpkg "$tmp/inc" "${stem%-*-*}" "${stem#"${stem%-*-*}"-}" "$arch" >/dev/null; done
}
# pooled REPO ARCH NAME-VERSION-ARCH -> the pooled file (hashed name)
pooled() { local -a m; shopt -s nullglob; m=("$pool/$1/os/$2/$3-"*.pkg.tar.zst); shopt -u nullglob; (( ${#m[@]} == 1 )) && printf '%s\n' "${m[0]}"; }

echo "--- a package, its debug package and their builder signatures, per arch"
up acl-2.4.0-1-x86_64.pkg.tar.zst acl-debug-2.4.0-1-x86_64.pkg.tar.zst
: >"$(ls "$tmp"/inc/acl-2.4.0-1-x86_64-*.pkg.tar.zst).buildsig"
[[ $(archci_pool "$tmp/inc" omarchy x86_64 2.4.0-1) == 2 ]] || fail "should pool 2"
p=$(pooled omarchy x86_64 acl-2.4.0-1-x86_64) && [[ -f $p ]] || fail "package not pooled: $(find "$pool")"
[[ $p =~ /acl-2\.4\.0-1-x86_64-[0-9a-f]{64}\.pkg\.tar\.zst$ ]] || fail "the pooled name carries the sha256: $p"
[[ $(sha256sum "$p" | cut -c1-64) == "${p: -76:64}" ]] || fail "the hash in the name is the file's"
[[ -f $p.buildsig ]] || fail "buildsig not carried"
[[ -f $(pooled omarchy-debug x86_64 acl-debug-2.4.0-1-x86_64) ]] || fail "debug package not in -debug"
[[ ! -e $pool/omarchy/os/aarch64 ]] || fail "x86_64 package must not land in aarch64"
[[ -z $(ls -A "$tmp/inc") ]] || fail "upload dir not emptied"

echo "--- an upload without the hash in its names (an older worker) gets it at ingest, buildsig renamed with it"
rm -rf "$tmp/inc"; mkdir -p "$tmp/inc"
old=$(UNHASHED=1 mkpkg "$tmp/inc" attr 2.6.0-1 x86_64)
: >"$old.buildsig"
[[ $(archci_pool "$tmp/inc" omarchy x86_64 2.6.0-1) == 1 ]] || fail "should pool the unhashed upload"
p=$(pooled omarchy x86_64 attr-2.6.0-1-x86_64) && [[ -f $p && -f $p.buildsig ]] || fail "unhashed upload must be pooled under its hashed name with its buildsig: $(ls "$pool/omarchy/os/x86_64")"
[[ ! -e $pool/omarchy/os/x86_64/attr-2.6.0-1-x86_64.pkg.tar.zst ]] || fail "the unhashed name must not reach the pool"

echo "--- an any package is pooled for every enabled arch"
up archlinux-keyring-20260901-1-any.pkg.tar.zst
: >"$(ls "$tmp"/inc/archlinux-keyring-*.pkg.tar.zst).buildsig"
[[ $(archci_pool "$tmp/inc" omarchy any 20260901-1) == 1 ]] || fail "should pool 1"
for a in x86_64 aarch64; do
	p=$(pooled omarchy $a archlinux-keyring-20260901-1-any) && [[ -f $p ]] || fail "any package missing for $a"
	[[ -f $p.buildsig ]] || fail "any buildsig missing for $a"
done

echo "--- a package of another arch (by its .PKGINFO), or of an arch not enabled, refuses the whole upload"
up bash-5.3-1-aarch64.pkg.tar.zst bash-5.3-1-x86_64.pkg.tar.zst
! archci_pool "$tmp/inc" omarchy x86_64 5.3-1 2>/dev/null || fail "aarch64 file in an x86_64 job must be refused"
! compgen -G "$pool/omarchy/os/x86_64/bash-5.3-1-x86_64-*" >/dev/null || fail "nothing may be pooled from a refused upload"
(( $(find "$tmp/inc" -type f | wc -l) == 2 )) || fail "a refused upload must be left intact"
up nano-8.0-1-riscv64.pkg.tar.zst
! archci_pool "$tmp/inc" omarchy riscv64 8.0-1 2>/dev/null || fail "an arch not in ARCHCI_ARCHES must be refused"
rm -rf "$tmp/inc"; mkdir -p "$tmp/inc"; echo "not a package" >"$tmp/inc/bogus-1-1-x86_64.pkg.tar.zst"
! archci_pool "$tmp/inc" omarchy x86_64 1-1 2>/dev/null || fail "a file without a .PKGINFO must be refused"

echo "--- the any arch's workers may upload their own arch for an any job; others may not"
up split-1-1-x86_64.pkg.tar.zst
[[ $(archci_pool "$tmp/inc" omarchy any 1-1) == 1 ]] || fail "x86_64 file from an any job on the any arch"
up split-1-1-aarch64.pkg.tar.zst
! archci_pool "$tmp/inc" omarchy any 1-1 2>/dev/null || fail "aarch64 file from an any job must be refused"

echo "--- an empty upload is a failure"
up
! archci_pool "$tmp/inc" omarchy x86_64 1-1 2>/dev/null || fail "empty upload must fail"
echo "ALL OK"
