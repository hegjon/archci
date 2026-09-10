#!/bin/bash
# scan-test.sh -- archci-scan, archci-next and archci-pkgs: the PKGBUILD
# repository is synced, nothing is queued ahead of time, the next package is
# picked from config (sources, extra packages, the repository URL) in the
# claim order.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
source "$here/fixture.sh"

echo "--- scan: syncs the PKGBUILD repository only, stores no backlog"
"$scan"
[[ -z $(ls -A "$ARCHCI_HOME/queue/pending") ]] || fail "scan must not create pending jobs"
[[ -d $ARCHCI_HOME/pkgbuilds/.git ]] || fail "scan must clone the PKGBUILD repository"
[[ $("$next") == "5 omarchy x86_64 acl 1:2.3.2-1 $(pkgcommit acl) extra" ]] || fail "archci-next: $("$next")"
"$master/archci-pkgs" | grep '^skipped 1-1 .* skip -$' >/dev/null || fail "archci-pkgs must list skip_build packages as skip"
[[ $("$next" | wc -l) == 1 ]] || fail "next prints one line"
! ARCHCI_PKG_SOURCES=local "$next" | grep . >/dev/null || fail "ARCHCI_PKG_SOURCES must filter by package.json source"
[[ $(ARCHCI_PKG_SOURCES=local ARCHCI_PKG_ALSO=acl "$next") == "5 omarchy x86_64 acl "* ]] || fail "ARCHCI_PKG_ALSO must build a named package regardless of source"
"$top" --json | ruby -rjson -e 'j=JSON.parse(STDIN.read); abort "outstanding #{j["outstanding"]}" unless j["outstanding"] == {"updates"=>0, "backlog"=>3}; abort "packages #{j["pkgbuilds"]}" unless j["pkgbuilds"]["packages"] == 3 && j["repo"] == "omarchy" && j["arches"] == ["x86_64"]'

echo "--- the PKGBUILD repository URL is config: a scan follows a changed one"
pkgs2=$tmp/pkgs2
git clone -q "$pkgs" "$pkgs2"
mkdir -p "$pkgs2/pkgbuilds/lib32-thing/.omarchy"
printf 'pkgname=lib32-thing\npkgver=1\npkgrel=1\narch=(x86_64)\n' >"$pkgs2/pkgbuilds/lib32-thing/PKGBUILD"
echo '{"source": "aur"}' >"$pkgs2/pkgbuilds/lib32-thing/.omarchy/package.json"
git -C "$pkgs2" add -A && git -C "$pkgs2" -c user.name=t -c user.email=t@t commit -qm fork
ARCHCI_PKGBUILDS_URL=file://$pkgs2 "$scan"
ARCHCI_PKGBUILDS_URL=file://$pkgs2 "$master/archci-pkgs" lib32-thing | grep '^lib32-thing 1-1 [0-9a-f]* x86_64 multilib aur build -$' >/dev/null || fail "fork's package missing or wrong profile"

echo "--- claim order: the farm's own packages, then core, extra, multilib, local, aur"
pkgs3=$tmp/pkgs3
git clone -q "$pkgs" "$pkgs3"
mk3() { mkdir -p "$pkgs3/pkgbuilds/$1/.omarchy"; printf 'pkgname=%s\npkgver=1\npkgrel=1\narch=(x86_64)\n' "$1" >"$pkgs3/pkgbuilds/$1/PKGBUILD"; printf '%s\n' "$2" >"$pkgs3/pkgbuilds/$1/.omarchy/package.json"; }
mk3 zz-core   '{"source": "arch", "arch_repo": "core"}'
mk3 aa-extra  '{"source": "arch", "arch_repo": "extra"}'
mk3 mm-local  '{"source": "local"}'
mk3 bb-aur    '{"source": "aur"}'
mk3 lib32-mul '{"source": "arch", "arch_repo": "multilib"}'
mk3 archci    '{"source": "local"}'
git -C "$pkgs3" add -A && git -C "$pkgs3" -c user.name=t -c user.email=t@t commit -qm order
order=$(ARCHCI_HOME=$tmp/home3 ARCHCI_PKGBUILDS_URL=file://$pkgs3 ARCHCI_PKG_ALSO=archci bash -c '
	mkdir -p "$ARCHCI_HOME"/{queue/{pending,running,done,failed},built,lock}
	"'"$scan"'" >/dev/null 2>&1
	ruby -e "require %q{'"$here"'/../lib/archci}; puts Archci.outstanding(arch: %q{x86_64}).map { |e| e[%q{pkgbase}] }.join(%q{ })"')
# the clone's own arch packages (no arch_repo) sort after multilib and before local
[[ $order =~ ^archci\ zz-core\ aa-extra\ lib32-mul\ .*\ mm-local\ bb-aur$ ]] || fail "claim order wrong: $order"
echo "ALL OK"
