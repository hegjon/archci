#!/bin/bash
# cache-test.sh -- archci_prune_cache: all but the newest KEEP versions of each
# package leave a pacman cache, signatures with them; 0 keeps everything.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export ARCHCI_CONF=/dev/null
source "$here/../lib/archci-common.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
c=$tmp/cache; mkdir -p "$c"
for f in foo-1.0-1-x86_64 foo-1.2-1-x86_64 foo-1.2-2-x86_64 foo-1:0.9-1-x86_64 lib32-foo-1.2-1-x86_64 bar-baz-2.0-3-any bar-baz-10.0-1-any; do
	: >"$c/$f.pkg.tar.zst"; : >"$c/$f.pkg.tar.zst.sig"
done
: >"$c/not-a-package.txt"

echo "--- keep 1: the newest version of each name stays, with its signature"
archci_prune_cache "$c" 1
find "$c" -maxdepth 1 -type f -printf "%f\\n" | sort | tr "\\n" " "; echo
[[ -f $c/foo-1:0.9-1-x86_64.pkg.tar.zst ]] || fail "epoch 1 is the newest foo"
[[ ! -e $c/foo-1.2-2-x86_64.pkg.tar.zst && ! -e $c/foo-1.2-2-x86_64.pkg.tar.zst.sig ]] || fail "older foo and its signature must go"
[[ -f $c/lib32-foo-1.2-1-x86_64.pkg.tar.zst ]] || fail "lib32-foo is another name"
[[ -f $c/bar-baz-10.0-1-any.pkg.tar.zst && ! -e $c/bar-baz-2.0-3-any.pkg.tar.zst ]] || fail "10.0 is newer than 2.0 (version sort), names may hold dashes"
[[ -f $c/not-a-package.txt ]] || fail "other files are left alone"
[[ $(find "$c" -maxdepth 1 -name "*.pkg.tar.zst" | wc -l) == 3 ]] || fail "one version per name"

echo "--- keep 0: nothing is deleted; a missing directory is fine"
: >"$c/foo-0.1-1-x86_64.pkg.tar.zst"
archci_prune_cache "$c" 0
[[ -f $c/foo-0.1-1-x86_64.pkg.tar.zst ]] || fail "keep 0 must not delete"
archci_prune_cache "$tmp/nope" 1
echo "ALL OK"
