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
up() { rm -rf "$tmp/inc"; mkdir -p "$tmp/inc"; local f; for f in "$@"; do echo "$f" >"$tmp/inc/$f"; done; }

echo "--- a package, its debug package and their builder signatures, per arch"
up acl-2.4.0-1-x86_64.pkg.tar.zst acl-debug-2.4.0-1-x86_64.pkg.tar.zst
: >"$tmp/inc/acl-2.4.0-1-x86_64.pkg.tar.zst.buildsig"
[[ $(archci_pool "$tmp/inc" omarchy x86_64 2.4.0-1) == 2 ]] || fail "should pool 2"
[[ -f $pool/omarchy/os/x86_64/acl-2.4.0-1-x86_64.pkg.tar.zst ]] || fail "package not pooled"
[[ -f $pool/omarchy/os/x86_64/acl-2.4.0-1-x86_64.pkg.tar.zst.buildsig ]] || fail "buildsig not carried"
[[ -f $pool/omarchy-debug/os/x86_64/acl-debug-2.4.0-1-x86_64.pkg.tar.zst ]] || fail "debug package not in -debug"
[[ ! -e $pool/omarchy/os/aarch64 ]] || fail "x86_64 package must not land in aarch64"
[[ -z $(ls -A "$tmp/inc") ]] || fail "upload dir not emptied"

echo "--- an any package is pooled for every enabled arch"
up archlinux-keyring-20260901-1-any.pkg.tar.zst
: >"$tmp/inc/archlinux-keyring-20260901-1-any.pkg.tar.zst.buildsig"
[[ $(archci_pool "$tmp/inc" omarchy any 20260901-1) == 1 ]] || fail "should pool 1"
for a in x86_64 aarch64; do
	[[ -f $pool/omarchy/os/$a/archlinux-keyring-20260901-1-any.pkg.tar.zst ]] || fail "any package missing for $a"
	[[ -f $pool/omarchy/os/$a/archlinux-keyring-20260901-1-any.pkg.tar.zst.buildsig ]] || fail "any buildsig missing for $a"
done

echo "--- a package of another arch, or of an arch not enabled, refuses the whole upload"
up attr-2.6.0-1-aarch64.pkg.tar.zst attr-2.6.0-1-x86_64.pkg.tar.zst
! archci_pool "$tmp/inc" omarchy x86_64 2.6.0-1 2>/dev/null || fail "aarch64 file in an x86_64 job must be refused"
[[ ! -e $pool/omarchy/os/x86_64/attr-2.6.0-1-x86_64.pkg.tar.zst ]] || fail "nothing may be pooled from a refused upload"
(( $(find "$tmp/inc" -type f | wc -l) == 2 )) || fail "a refused upload must be left intact"
up nano-8.0-1-riscv64.pkg.tar.zst
! archci_pool "$tmp/inc" omarchy riscv64 8.0-1 2>/dev/null || fail "an arch not in ARCHCI_ARCHES must be refused"

echo "--- the any arch's workers may upload their own arch for an any job; others may not"
up split-1-1-x86_64.pkg.tar.zst
[[ $(archci_pool "$tmp/inc" omarchy any 1-1) == 1 ]] || fail "x86_64 file from an any job on the any arch"
up split-1-1-aarch64.pkg.tar.zst
! archci_pool "$tmp/inc" omarchy any 1-1 2>/dev/null || fail "aarch64 file from an any job must be refused"

echo "--- an empty upload is a failure"
up
! archci_pool "$tmp/inc" omarchy x86_64 1-1 2>/dev/null || fail "empty upload must fail"
echo "ALL OK"
