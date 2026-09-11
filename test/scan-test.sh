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
"$master/archci-pkgs" | grep '^skipped 1-1 .* skip - skipped -$' >/dev/null || fail "archci-pkgs must list skip_build packages as skip, with pkgnames and deps: $("$master/archci-pkgs" skipped)"
[[ $("$next" | wc -l) == 1 ]] || fail "next prints one line"
echo "--- the index caches each directory's line by its tree hash"
cache=$ARCHCI_HOME/pkgbuilds.cache
[[ $(wc -l <"$cache") == 4 ]] || fail "one cache entry per package directory: $(cat "$cache")"
# a line served from the cache is not re-read: doctor acl's entry, change another package, and see it used
sed -i 's/^\([0-9a-f]* \)1:2.3.2-1 /\19:9-9 /' "$cache"
mkpkgbuild linux 7.2.3.arch1-3
commit_pkgs "linux bump"
"$scan" >/dev/null
"$master/archci-pkgs" acl | grep '^acl 9:9-9 ' >/dev/null || fail "an unchanged directory must come from the cache: $("$master/archci-pkgs" acl)"
"$master/archci-pkgs" linux | grep '^linux 7.2.3.arch1-3 ' >/dev/null || fail "a changed directory must be re-read: $("$master/archci-pkgs" linux)"
[[ $(wc -l <"$cache") == 4 ]] || fail "the old entry of a changed directory is dropped: $(cat "$cache")"
# without the cache everything is re-read
rm -f "$cache" "$ARCHCI_HOME/pkgbuilds.index"
"$master/archci-pkgs" acl | grep '^acl 1:2.3.2-1 ' >/dev/null || fail "without the cache the PKGBUILD is read: $("$master/archci-pkgs" acl)"
mkpkgbuild linux 7.2.3.arch1-2; commit_pkgs "linux back"; "$scan" >/dev/null   # the rest of the test expects the original set
! ARCHCI_PKG_SOURCES=local "$next" | grep . >/dev/null || fail "ARCHCI_PKG_SOURCES must filter by package.json source"
[[ $(ARCHCI_PKG_SOURCES=local ARCHCI_PKG_ALSO=acl "$next") == "5 omarchy x86_64 acl "* ]] || fail "ARCHCI_PKG_ALSO must build a named package regardless of source"
frame=$("$top")
[[ $frame == *"pkgbuilds -> [omarchy]   arches: x86_64"* && $frame == *"outstanding: 0 update(s), 3 unbuilt"* && $frame == *"built: x86_64 0/3"* ]] || fail "top frame: $frame"

echo "--- the PKGBUILD repository URL is config: a scan follows a changed one"
pkgs2=$tmp/pkgs2
git clone -q "$pkgs" "$pkgs2"
mkdir -p "$pkgs2/pkgbuilds/lib32-thing/.omarchy"
printf 'pkgname=lib32-thing\npkgver=1\npkgrel=1\narch=(x86_64)\n' >"$pkgs2/pkgbuilds/lib32-thing/PKGBUILD"
echo '{"source": "aur"}' >"$pkgs2/pkgbuilds/lib32-thing/.omarchy/package.json"
git -C "$pkgs2" add -A && git -C "$pkgs2" -c user.name=t -c user.email=t@t commit -qm fork
ARCHCI_PKGBUILDS_URL=file://$pkgs2 "$scan"
ARCHCI_PKGBUILDS_URL=file://$pkgs2 "$master/archci-pkgs" lib32-thing | grep '^lib32-thing 1-1 [0-9a-f]* x86_64 multilib aur build - lib32-thing -$' >/dev/null || fail "fork's package missing or wrong profile"

echo "--- claim order: the farm's own packages, then core, extra, multilib, local, aur"
pkgs3=$tmp/pkgs3
git clone -q "$pkgs" "$pkgs3"
mk3() {   # mk3 NAME JSON [DEPENDS...]
	mkdir -p "$pkgs3/pkgbuilds/$1/.omarchy"
	printf 'pkgname=%s\npkgver=1\npkgrel=1\narch=(x86_64)\ndepends=(%s)\n' "$1" "${*:3}" >"$pkgs3/pkgbuilds/$1/PKGBUILD"
	printf '%s\n' "$2" >"$pkgs3/pkgbuilds/$1/.omarchy/package.json"
}
mk3 zz-core   '{"source": "arch", "arch_repo": "core"}'
mk3 aa-extra  '{"source": "arch", "arch_repo": "extra"}'
mk3 mm-local  '{"source": "local"}'
mk3 bb-aur    '{"source": "aur"}'
mk3 lib32-mul '{"source": "arch", "arch_repo": "multilib"}'
mk3 archci    '{"source": "local"}'
# aa-app needs bb-lib (by its pkgname, with a version constraint) and a
# library of Arch's: it waits for bb-lib, not for Arch
mk3 aa-app    '{"source": "local"}' "'bb-lib>=1'" glibc
mk3 bb-lib    '{"source": "local"}'
git -C "$pkgs3" add -A && git -C "$pkgs3" -c user.name=t -c user.email=t@t commit -qm order
# the order, each package with the dependencies it waits for in parentheses, and ! when one of them is being built or retried
next3() { ARCHCI_HOME=$tmp/home3 ARCHCI_PKGBUILDS_URL=file://$pkgs3 ARCHCI_PKG_ALSO=archci ruby -e "require %q{$here/../lib/archci}; puts Archci.outstanding(arch: %q{x86_64}).map { |e| e[%q{pkgbase}] + (e[%q{waiting}].empty? ? %q{} : %q{(} + e[%q{waiting}].join(%q{,}) + %q{)}) + (e[%q{expected}] ? %q{!} : %q{}) }.join(%q{ })"; }
mkdir -p "$tmp/home3"/{queue/{pending,running,done,failed},built,lock}
ARCHCI_HOME=$tmp/home3 ARCHCI_PKGBUILDS_URL=file://$pkgs3 "$scan" >/dev/null 2>&1
order=$(next3)
# the clone's own arch packages (no arch_repo) sort after multilib and before local
[[ $order == "archci zz-core aa-extra lib32-mul "*" bb-lib mm-local bb-aur aa-app(bb-lib)" ]] || fail "claim order wrong: $order"
# a dependency that gave up at its current commit is not waited for either
c=$(git -C "$pkgs3" log -1 --format=%H -- pkgbuilds/bb-lib)
printf 'id=5-1-omarchy,bb-lib,1-1,x86_64\nrepo=omarchy\narch=x86_64\npkgbase=bb-lib\nversion=1-1\ncommit=%s\nprofile=extra\ncreated=2026-01-01T00:00:00Z\nattempt=3\nworker=w\nstatus=failure\nfinished=2026-01-01T01:00:00Z\nfinal=1\n' "$c" >"$tmp/home3/queue/failed/5-1-omarchy,bb-lib,1-1,x86_64.job"
order=$(next3)
[[ $order == *" aa-app mm-local bb-aur" ]] || fail "a dependency that gave up must not hold its dependents back: $order"
rm -f "$tmp/home3/queue/failed/5-1-omarchy,bb-lib,1-1,x86_64.job"
# bb-lib being built (or retried): aa-app is expected to follow, archci-next passes it over
printf 'id=5-1-omarchy,bb-lib,1-1,x86_64\nrepo=omarchy\narch=x86_64\npkgbase=bb-lib\nversion=1-1\ncommit=%s\nprofile=extra\ncreated=2026-01-01T00:00:00Z\nattempt=1\nworker=w\nclaimed=2026-01-01T01:00:00Z\n' "$c" >"$tmp/home3/queue/running/5-1-omarchy,bb-lib,1-1,x86_64.job"
order=$(next3)
[[ $order == *" aa-app(bb-lib)!" ]] || fail "a package whose dependency is being built must be marked expected: $order"
# among the local packages, with archci and mm-local built, aa-app is all that is left: archci-next offers nothing while bb-lib builds
mkdir -p "$tmp/home3/built/omarchy-x86_64"
echo "1-1 x" >"$tmp/home3/built/omarchy-x86_64/archci"; echo "1-1 x" >"$tmp/home3/built/omarchy-x86_64/mm-local"
next3local() { ARCHCI_HOME=$tmp/home3 ARCHCI_PKGBUILDS_URL=file://$pkgs3 ARCHCI_PKG_SOURCES=local "$master/archci-next" x86_64; }
[[ -z $(next3local) ]] || fail "archci-next must pass over a package whose dependency is being built: $(next3local)"
rm -f "$tmp/home3/queue/running/5-1-omarchy,bb-lib,1-1,x86_64.job"
[[ $(next3local) == "5 omarchy x86_64 bb-lib "* ]] || fail "with the dependency's build gone, the dependency itself is next: $(next3local)"
echo "1-1 x" >"$tmp/home3/built/omarchy-x86_64/bb-lib"; printf 'id=5-2-omarchy,bb-lib,1-1,x86_64\nrepo=omarchy\narch=x86_64\npkgbase=bb-lib\nversion=1-1\ncommit=%s\nprofile=extra\ncreated=2026-01-01T00:00:00Z\nattempt=1\nworker=w\nstatus=failure\nfinished=2026-01-01T01:00:00Z\n' "$c" >"$tmp/home3/queue/failed/5-2-omarchy,bb-lib,1-1,x86_64.job"
echo "0-1 x" >"$tmp/home3/built/omarchy-x86_64/bb-lib"
[[ -z $(next3local) ]] || fail "a dependency's retry pending counts as expected too: $(next3local)"
rm -f "$tmp/home3/queue/failed/5-2-omarchy,bb-lib,1-1,x86_64.job" "$tmp/home3/built/omarchy-x86_64/bb-lib"
rm -f "$tmp/home3/built/omarchy-x86_64/archci" "$tmp/home3/built/omarchy-x86_64/mm-local"
# bb-lib built at an older version: aa-app waits for its update; and as an
# update itself it comes after the backlog, not before it
mkdir -p "$tmp/home3/built/omarchy-x86_64"; echo "0-1 x" >"$tmp/home3/built/omarchy-x86_64/bb-lib"
echo "0-1 x" >"$tmp/home3/built/omarchy-x86_64/aa-app"
order=$(next3)
[[ $order == "archci bb-lib zz-core "*" mm-local bb-aur aa-app(bb-lib)" ]] || fail "a dependency built at an older version must be waited for (its update, bb-lib, goes first), and an update waiting comes after the backlog: $order"
# bb-lib built at its version but just now: not released yet, still waited for
echo "1-1 x" >"$tmp/home3/built/omarchy-x86_64/bb-lib"
order=$(ARCHCI_RELEASE_LAG_MINUTES=10 next3)
[[ $order == *" aa-app(bb-lib)" ]] || fail "a dependency built within the release lag must be waited for: $order"
# built long enough ago: aa-app, an update, goes first after the farm's own
order=$(next3)
[[ $order == "archci aa-app zz-core "* ]] || fail "an update whose dependency is built must not wait: $order"
echo "ALL OK"
