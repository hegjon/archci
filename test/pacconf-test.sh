#!/bin/bash
# shellcheck disable=SC2016  # $repo/$arch are pacman placeholders, literal on purpose
# pacconf-test.sh -- archci_chroot_pacconf: the farm's repository goes above
# the first repository of a chroot pacman.conf, once, and a config that
# already names it is left alone.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export ARCHCI_CONF=/dev/null ARCHCI_RELEASE_URL=https://pub-x.r2.dev   # the repo is the job's, not this worker's ARCHCI_REPO
source "$here/../lib/archci-common.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "--- inserted above the first repository, after [options]"
printf '[options]\nArchitecture = auto\nSigLevel = Required DatabaseOptional\n\n#[core-testing]\n#Include = /etc/pacman.d/mirrorlist\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n' >"$tmp/extra.conf"
archci_chroot_pacconf "$tmp/extra.conf" "$tmp/out/extra-x86_64.conf" hegjon-test x86_64
out=$tmp/out/extra-x86_64.conf
grep -n '^\[' "$out" | head -3
[[ $(grep '^\[' "$out" | head -2 | tr '\n' ' ') == "[options] [hegjon-test] " ]] || fail "the farm's repo must follow [options]: $(grep '^\[' "$out" | tr '\n' ' ')"
[[ $(grep -c '^\[hegjon-test\]' "$out") == 1 ]] || fail "inserted once"
grep -qx 'Server = https://pub-x.r2.dev/$repo/os/$arch' "$out" || fail "server line: $(grep Server "$out")"
grep -A2 '^\[hegjon-test\]' "$out" | grep '^SigLevel = Required DatabaseOptional' >/dev/null || fail "signatures required"
[[ $(grep -c "^\[" "$out") == 4 ]] || fail "the other repositories stay: $(grep -c "^\[" "$out")"
bash -c 'pacman-conf --config "$1" --repo-list' _ "$out" | head -1 | grep -x hegjon-test >/dev/null || fail "pacman-conf must list it first: $(pacman-conf --config "$out" --repo-list | tr '\n' ' ')"
[[ $(pacman-conf --config "$out" CacheDir) == /var/cache/archci/pkg/hegjon-test-x86_64/ ]] || fail "a cache of the repo's own, not the mirrors': $(pacman-conf --config "$out" CacheDir)"

echo "--- a port config with a cache of its own gets this repo's instead"
printf '[options]\nCacheDir    = /var/cache/archci/pkg/aarch64/\nArchitecture = aarch64\n[core]\nServer = https://p/$repo/os/$arch\n' >"$tmp/port.conf"
archci_chroot_pacconf "$tmp/port.conf" "$tmp/out/port.conf" hegjon-test aarch64
[[ $(pacman-conf --config "$tmp/out/port.conf" CacheDir) == /var/cache/archci/pkg/hegjon-test-aarch64/ ]] || fail "port cache: $(pacman-conf --config "$tmp/out/port.conf" CacheDir)"
[[ $(grep -c '^CacheDir' "$tmp/out/port.conf") == 1 ]] || fail "one CacheDir"

echo "--- a config that already names the repository is copied as is"
printf '[options]\n[hegjon-test]\nServer = file:///x\n[core]\nServer = https://m/$repo/os/$arch\n' >"$tmp/own.conf"
archci_chroot_pacconf "$tmp/own.conf" "$tmp/out/own.conf" hegjon-test x86_64
cmp -s "$tmp/own.conf" "$tmp/out/own.conf" || fail "must not touch a config that has the repo"

echo "--- rewritten in place on a second run"
archci_chroot_pacconf "$tmp/extra.conf" "$out" hegjon-test x86_64
[[ $(grep -c '^\[hegjon-test\]' "$out") == 1 ]] || fail "still once"
echo "ALL OK"
