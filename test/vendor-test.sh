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
[[ -z $(archci_vendor_env go capture /vendor) ]] || fail "go is not captured yet"
archci_vendor_supported rust || fail "rust is supported"
! archci_vendor_supported go || fail "go is not supported yet"

echo "--- archci_srcpkg_add_vendor: vendor/ joins the source package under its pkgbase"
mkdir -p "$tmp/pkg/hello" "$tmp/vendor/rust/registry/cache"
echo pkg >"$tmp/pkg/hello/PKGBUILD"; echo crate >"$tmp/vendor/rust/registry/cache/serde-1.0.crate"
tar -czf "$tmp/hello-1-1.src.tar.gz" -C "$tmp/pkg" hello
archci_srcpkg_add_vendor "$tmp/hello-1-1.src.tar.gz" hello "$tmp/vendor" || fail "adding vendor/ failed"
tar -tzf "$tmp/hello-1-1.src.tar.gz" | grep -qx "hello/vendor/rust/registry/cache/serde-1.0.crate" || fail "the crate must sit under hello/vendor/rust: $(tar -tzf "$tmp/hello-1-1.src.tar.gz")"
tar -tzf "$tmp/hello-1-1.src.tar.gz" | grep -qx "hello/PKGBUILD" || fail "the PKGBUILD must still be there"
[[ ! -e $tmp/hello-1-1.src.tar.gz.tar ]] || fail "the plain tar must be cleaned up"
echo "ALL OK"
