#!/bin/bash
# phase-test.sh -- archci_phase_filter: the build's output passes through, and
# each marker line sets the phase file to makepkg's step in eight characters.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export ARCHCI_CONF=/dev/null
source "$here/../lib/archci-common.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
f=$tmp/phase
out=$(printf '%s\n' '==> Synchronizing chroot copy [x] -> [y]...' 'line one' '==> Installing missing dependencies...' '==> Making package: acl 2.4.0-1 (Thu)' '==> Retrieving sources...' '==> Validating source files with sha256sums...' '==> Starting prepare()...' 'gcc -c foo.c' '==> Starting build()...' '==> Starting package_acl-debug()...' '==> Creating package "acl"...' | archci_phase_filter "$f")
[[ $(wc -l <<<"$out") == 11 ]] || fail "every line must pass through: $(wc -l <<<"$out")"
[[ $out == *'gcc -c foo.c'* ]] || fail "lines are passed through unchanged"
[[ $(<"$f") == compress ]] || fail "the last marker wins: $(<"$f")"
for m in 'Starting check()' 'Starting pkgver()' 'Extracting sources' 'Verifying source file signatures with gpg' 'Updating chroot'; do
	printf '==> %s...\n' "$m" | archci_phase_filter "$f" >/dev/null
	echo "$m -> $(<"$f")"
done
[[ $(<"$f") == update ]] || fail "update"
printf '==> Starting package_something-long()...\n' | archci_phase_filter "$f" >/dev/null
[[ $(<"$f") == package ]] || fail "a split package function is package: $(<"$f")"
printf 'no marker here\n' | archci_phase_filter "$f" >/dev/null
[[ $(<"$f") == package ]] || fail "a plain line changes nothing"
[[ ! -e $f.tmp ]] || fail "no temp file left"
echo "ALL OK"
