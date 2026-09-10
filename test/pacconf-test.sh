#!/bin/bash
# shellcheck disable=SC2016  # $repo/$arch are pacman placeholders, literal on purpose
# pacconf-test.sh -- archci_chroot_pacconf: the farm's repository goes above
# the first repository of a chroot pacman.conf, once, and a config that
# already names it is left alone.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export ARCHCI_CONF=/dev/null ARCHCI_REPO=hegjon-test ARCHCI_RELEASE_URL=https://pub-x.r2.dev
source "$here/../lib/archci-common.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "--- inserted above the first repository, after [options]"
printf '[options]\nArchitecture = auto\nSigLevel = Required DatabaseOptional\n\n#[core-testing]\n#Include = /etc/pacman.d/mirrorlist\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\n\n[extra]\nInclude = /etc/pacman.d/mirrorlist\n' >"$tmp/extra.conf"
archci_chroot_pacconf "$tmp/extra.conf" "$tmp/out/extra-x86_64.conf"
out=$tmp/out/extra-x86_64.conf
grep -n '^\[' "$out" | head -3
[[ $(grep '^\[' "$out" | head -2 | tr '\n' ' ') == "[options] [hegjon-test] " ]] || fail "the farm's repo must follow [options]: $(grep '^\[' "$out" | tr '\n' ' ')"
[[ $(grep -c '^\[hegjon-test\]' "$out") == 1 ]] || fail "inserted once"
grep -qx 'Server = https://pub-x.r2.dev/$repo/os/$arch' "$out" || fail "server line: $(grep Server "$out")"
grep -A2 '^\[hegjon-test\]' "$out" | grep -q '^SigLevel = Required DatabaseOptional' || fail "signatures required"
[[ $(grep -c "^\[" "$out") == 4 ]] || fail "the other repositories stay: $(grep -c "^\[" "$out")"
bash -c 'pacman-conf --config "$1" --repo-list' _ "$out" | head -1 | grep -qx hegjon-test || fail "pacman-conf must list it first: $(pacman-conf --config "$out" --repo-list | tr '\n' ' ')"

echo "--- a config that already names the repository is copied as is"
printf '[options]\n[hegjon-test]\nServer = file:///x\n[core]\nServer = https://m/$repo/os/$arch\n' >"$tmp/own.conf"
archci_chroot_pacconf "$tmp/own.conf" "$tmp/out/own.conf"
cmp -s "$tmp/own.conf" "$tmp/out/own.conf" || fail "must not touch a config that has the repo"

echo "--- rewritten in place on a second run"
archci_chroot_pacconf "$tmp/extra.conf" "$out"
[[ $(grep -c '^\[hegjon-test\]' "$out") == 1 ]] || fail "still once"
echo "ALL OK"
