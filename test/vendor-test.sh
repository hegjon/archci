#!/bin/bash
# vendor-test.sh -- the vendored dependencies' pieces: which ecosystems a
# PKGBUILD fetches, the environment that captures and replays them, and
# the vendor/ tree going into a source package.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export ARCHCI_CONF=/dev/null
source "$here/../lib/archci-common.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "--- archci_vendor_kinds: the ecosystems a PKGBUILD fetches in prepare()"
cat >"$tmp/rust" <<'P'
prepare() {
  cargo fetch --locked --target "$(rustc --print host-tuple)"
}
build() { cargo build --frozen --release; }
P
[[ $(archci_vendor_kinds "$tmp/rust") == rust ]] || fail "a cargo fetch is rust: $(archci_vendor_kinds "$tmp/rust")"
# shellcheck disable=SC2016  # a PKGBUILD line, literally
printf 'prepare() {\n  go mod download\n  npm ci --cache "$srcdir/npm-cache"\n}\n' >"$tmp/gonpm"
[[ $(archci_vendor_kinds "$tmp/gonpm" | tr '\n' ' ') == "go npm " ]] || fail "go and npm both: $(archci_vendor_kinds "$tmp/gonpm")"
printf 'build() {\n  make\n}\n' >"$tmp/plain"
[[ -z $(archci_vendor_kinds "$tmp/plain") ]] || fail "a plain build fetches nothing: $(archci_vendor_kinds "$tmp/plain")"
printf 'pkgname=cargo-c\nbuild() { make; }\n' >"$tmp/name"
[[ -z $(archci_vendor_kinds "$tmp/name") ]] || fail "a package name is not a fetch"

echo "--- archci_vendor_env: capture directs the cache, replay forbids the network"
[[ $(archci_vendor_env rust capture /vendor) == "CARGO_HOME=/vendor/rust" ]] || fail "rust capture: $(archci_vendor_env rust capture /vendor)"
[[ $(archci_vendor_env rust replay /startdir/vendor | tr '\n' ' ') == "CARGO_HOME=/startdir/vendor/rust CARGO_NET_OFFLINE=true " ]] || fail "rust replay: $(archci_vendor_env rust replay /startdir/vendor)"
[[ $(archci_vendor_env go replay /startdir/vendor | tr '\n' ' ') == "GOMODCACHE=/startdir/vendor/go GOFLAGS=-mod=mod GOPROXY=off " ]] || fail "go replay: $(archci_vendor_env go replay /startdir/vendor)"
[[ $(archci_vendor_env npm replay /v | head -2 | tr '\n' ' ') == "npm_config_cache=/v/npm npm_config_offline=true " ]] || fail "npm replay: $(archci_vendor_env npm replay /v)"
[[ $(archci_vendor_env pip capture /v) == "PIP_CACHE_DIR=/v/pip" ]] || fail "pip capture: $(archci_vendor_env pip capture /v)"
[[ $(archci_vendor_env maven replay /v | tr '\n' ' ') == "MAVEN_OPTS=-Dmaven.repo.local=/v/maven MAVEN_ARGS=--offline GRADLE_USER_HOME=/v/gradle " ]] || fail "maven replay: $(archci_vendor_env maven replay /v)"
mkdir -p "$tmp/rv/maven"; archci_vendor_replay_files maven "$tmp/rv"
grep -qx 'gradle.startParameter.offline = true' "$tmp/rv/maven/gradle/init.d/archci-offline.gradle" || fail "the maven replay must write gradle's offline init script"
archci_vendor_replay_files rust "$tmp/rv"; [[ ! -e $tmp/rv/rust ]] || fail "rust needs no replay files"
for k in rust go npm pip maven; do archci_vendor_supported "$k" || fail "$k is supported"; done
! archci_vendor_supported perl || fail "an unknown kind is not"
[[ -z $(archci_vendor_env perl capture /v) ]] || fail "an unknown kind has no environment"

echo "--- archci_firewall: the table for the offline slice (needs nft and root; skipped without)"
if command -v nft >/dev/null && [[ $EUID == 0 ]]; then
	archci_firewall || fail "archci_firewall must install its table"
	nft list table inet archci | grep -q 'archci.slice/archci-offline.slice" counter reject' || fail "the offline slice must reach nothing"
	nft list table inet archci | grep -q 'archci.slice/archci-loopback.slice" oifname != "lo"' || fail "the loopback slice must reach loopback only"
	nft delete table inet archci
else
	echo "(not root, or no nft: skipped)"
fi
echo "--- archci_machine_name: a hostname from a package name"
[[ $(archci_machine_name archci-build-x86_64-1 'libsigc++') == archci-build-x86-64-1-libsigc-- ]] || fail "machine name: $(archci_machine_name archci-build-x86_64-1 'libsigc++')"
long=$(archci_machine_name archci-build "$(printf 'x%.0s' {1..100})")
(( ${#long} <= 64 )) || fail "a machine name is at most 64 characters: ${#long}"

echo "--- archci_srcpkg_add_vendor: vendor/ joins the source package under its pkgbase"
mkdir -p "$tmp/pkg/hello" "$tmp/vendor/rust/registry/cache"
echo pkg >"$tmp/pkg/hello/PKGBUILD"; echo crate >"$tmp/vendor/rust/registry/cache/serde-1.0.crate"
tar -czf "$tmp/hello-1-1.src.tar.gz" -C "$tmp/pkg" hello
archci_srcpkg_add_vendor "$tmp/hello-1-1.src.tar.gz" hello "$tmp/vendor" || fail "adding vendor/ failed"
tar -tzf "$tmp/hello-1-1.src.tar.gz" | grep -qx "hello/vendor/rust/registry/cache/serde-1.0.crate" || fail "the crate must sit under hello/vendor/rust: $(tar -tzf "$tmp/hello-1-1.src.tar.gz")"
tar -tzf "$tmp/hello-1-1.src.tar.gz" | grep -qx "hello/PKGBUILD" || fail "the PKGBUILD must still be there"
[[ ! -e $tmp/hello-1-1.src.tar.gz.tar ]] || fail "the plain tar must be cleaned up"
echo "ALL OK"
