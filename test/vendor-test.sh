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
	table=$(nft list table inet archci)
	grep -q 'archci.slice/archci-offline.slice" counter reject' <<<"$table" || fail "the offline slice must reach nothing"
	grep -q 'archci.slice/archci-loopback.slice" oifname != "lo"' <<<"$table" || fail "the loopback slice must reach loopback only"
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
# (into a variable first: a pipe into grep -q ends with tar's SIGPIPE under pipefail when grep quits at the first entry)
entries=$(tar -tzf "$tmp/hello-1-1.src.tar.gz")
grep -qx "hello/vendor/rust/registry/cache/serde-1.0.crate" <<<"$entries" || fail "the crate must sit under hello/vendor/rust: $entries"
grep -qx "hello/PKGBUILD" <<<"$entries" || fail "the PKGBUILD must still be there: $entries"
[[ ! -e $tmp/hello-1-1.src.tar.gz.tar ]] || fail "the plain tar must be cleaned up"

echo "--- archci_sbom: a CycloneDX SBOM of the vendored rust/go/npm deps"
sb=$tmp/sbomvendor/rust/registry/cache/index.crates.io-abc
mkdir -p "$sb"
for c in serde-1.0.228 time-core-0.1.8 openssl-src-300.5.5+3.5.5 clap_derive-4.5.55; do echo "$c" >"$sb/$c.crate"; done
bom=$(archci_sbom "$tmp/sbomvendor" eza 0.23.5-2.1)
jq -e . <<<"$bom" >/dev/null || fail "the SBOM must be valid JSON: $bom"
[[ $(jq -r .bomFormat <<<"$bom") == CycloneDX && $(jq -r .specVersion <<<"$bom") == 1.5 ]] || fail "SBOM must be CycloneDX 1.5"
[[ $(jq -r .metadata.component.name <<<"$bom") == eza && $(jq -r .metadata.component.version <<<"$bom") == 0.23.5-2.1 ]] || fail "the package is the top component"
[[ $(jq '.components | length' <<<"$bom") == 4 ]] || fail "one component per crate: $(jq '.components|length' <<<"$bom")"
# the name/version split handles hyphens and build metadata
[[ $(jq -r '.components[] | select(.name=="time-core") | .version' <<<"$bom") == 0.1.8 ]] || fail "time-core split wrong"
[[ $(jq -r '.components[] | select(.name=="openssl-src") | .version' <<<"$bom") == "300.5.5+3.5.5" ]] || fail "openssl-src build metadata split wrong"
[[ $(jq -r '.components[] | select(.name=="serde") | .purl' <<<"$bom") == "pkg:cargo/serde@1.0.228" ]] || fail "purl wrong"
[[ $(jq -r '.components[] | select(.name=="serde") | .hashes[0].alg' <<<"$bom") == "SHA-256" ]] || fail "each crate has a SHA-256"
[[ $(jq -r '.components[] | select(.name=="serde") | .hashes[0].content' <<<"$bom") == "$(sha256sum "$sb/serde-1.0.228.crate" | cut -d' ' -f1)" ]] || fail "the hash must be the crate's sha256"

echo "--- archci_sbom: go modules (pkg:golang, name unescaped, sha256 of the zip)"
gm="$tmp/sbomvendor/go/cache/download/github.com/!burnt!sushi/toml/@v"
mkdir -p "$gm"; echo zip >"$gm/v1.4.0.zip"
gm2="$tmp/sbomvendor/go/cache/download/golang.org/x/net/@v"; mkdir -p "$gm2"; echo zip >"$gm2/v0.38.0.zip"
bom=$(archci_sbom "$tmp/sbomvendor" eza 0.23.5-2.1)
jq -e . <<<"$bom" >/dev/null || fail "SBOM with go must be valid JSON: $bom"
[[ $(jq -r '.components[] | select(.name=="github.com/BurntSushi/toml") | .purl' <<<"$bom") == "pkg:golang/github.com/BurntSushi/toml@v1.4.0" ]] || fail "go module name must be unescaped (!burnt!sushi -> BurntSushi): $(jq -c '[.components[]|select(.purl|startswith("pkg:golang"))]' <<<"$bom")"
[[ $(jq -r '.components[] | select(.name=="golang.org/x/net") | .version' <<<"$bom") == "v0.38.0" ]] || fail "go module version from the zip name"
[[ $(jq -r '.components[] | select(.name=="golang.org/x/net") | .hashes[0].content' <<<"$bom") == "$(sha256sum "$gm2/v0.38.0.zip" | cut -d' ' -f1)" ]] || fail "go module hash must be the zip sha256"

echo "--- archci_sbom: npm packages (pkg:npm from the cacache index, incl. scoped)"
ni="$tmp/sbomvendor/npm/_cacache/index-v5/aa/bb"; mkdir -p "$ni"
b64=$(printf 'x' | sha512sum | cut -d' ' -f1 | xxd -r -p | base64 -w0 2>/dev/null || printf '')
printf 'deadbeef\t{"key":"make-fetch-happen:request-cache:https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz","integrity":"sha512-%s"}\n' "$b64" >"$ni/idx1"
printf 'deadbeef\t{"key":"make-fetch-happen:request-cache:https://registry.npmjs.org/@types%%2fnode/-/node-20.11.0.tgz","integrity":"sha512-%s"}\n' "$b64" >"$ni/idx2"
bom=$(archci_sbom "$tmp/sbomvendor" eza 0.23.5-2.1)
jq -e . <<<"$bom" >/dev/null || fail "SBOM with npm must be valid JSON: $bom"
[[ $(jq -r '.components[] | select(.name=="lodash") | .purl' <<<"$bom") == "pkg:npm/lodash@4.17.21" ]] || fail "npm unscoped package: $(jq -c '[.components[]|select(.purl|startswith("pkg:npm"))]' <<<"$bom")"
[[ $(jq -r '.components[] | select(.name=="@types/node") | .purl' <<<"$bom") == "pkg:npm/%40types/node@20.11.0" ]] || fail "npm scoped package must decode @types/node and %40-encode the PURL"
[[ $(jq -r '.components[] | select(.name=="lodash") | .hashes[0].alg' <<<"$bom") == "SHA-512" ]] || fail "npm hash from the integrity is SHA-512"

echo "--- archci_srcpkg_add_file: the SBOM joins the source package under its pkgbase"
echo "$bom" >"$tmp/sbom.cdx.json"
archci_srcpkg_add_file "$tmp/hello-1-1.src.tar.gz" hello "$tmp/sbom.cdx.json" sbom.cdx.json || fail "adding the SBOM failed"
tar -tzf "$tmp/hello-1-1.src.tar.gz" | grep -qx "hello/sbom.cdx.json" || fail "the SBOM must sit at hello/sbom.cdx.json"
echo "ALL OK"
