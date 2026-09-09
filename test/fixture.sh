# shellcheck shell=bash
# fixture.sh -- what the master-side tests share: a throwaway ARCHCI_HOME, a
# fake PKGBUILD repository in the omarchy-pkgs layout (pkgbuilds/<name>/PKGBUILD
# plus .omarchy/package.json) with four packages, paths to the scripts and
# helpers for fake packages and claims. Runs without network or root. Source it
# after setting $here (the test directory); it sets $tmp and removes it on exit.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export ARCHCI_CONF=/dev/null ARCHCI_HOME=$tmp/home ARCHCI_REPO=omarchy ARCHCI_ARCH=x86_64
export ARCHCI_MAX_ATTEMPTS=2 ARCHCI_STALE_MINUTES=0 ARCHCI_RETRY_MINUTES=0 JOURNAL_STREAM=1
master=$here/../master
job=$master/archci-job
scan=$master/archci-scan
next=$master/archci-next
housekeeping=$master/internal/archci-housekeeping
top=$master/archci-top
fail() { echo "FAIL: $*" >&2; exit 1; }
# mkpkg DIR NAME VERSION [ARCH] -- smallest thing repo-add accepts as a package
mkpkg() {
	local d=$tmp/mkpkg arch=${4:-x86_64}; rm -rf "$d"; mkdir -p "$d"
	printf 'pkgname = %s\npkgbase = %s\npkgver = %s\npkgdesc = fake\nurl = x\nbuilddate = 1\npackager = t\nsize = 0\narch = %s\n' \
		"$2" "${2%-debug}" "$3" "$arch" >"$d/.PKGINFO"
	bsdtar -C "$d" -cf - .PKGINFO | zstd -q >"$1/$2-$3-$arch.pkg.tar.zst"
}
# mkpkgbuild NAME VERSION [ARCH] [JSON] -- VERSION is [epoch:]pkgver-pkgrel
mkpkgbuild() {
	local d=$pkgs/pkgbuilds/$1 v=$2 epoch='' arch=${3:-x86_64}
	[[ $v == *:* ]] && { epoch=${v%%:*}; v=${v#*:}; }
	mkdir -p "$d/.omarchy"
	printf 'pkgname=%s\npkgver=%s\npkgrel=%s\n%sarch=(%s)\n' "$1" "${v%-*}" "${v##*-}" "${epoch:+epoch=$epoch
}" "$arch" >"$d/PKGBUILD"
	printf '%s\n' "${4:-{\"source\": \"arch\"\}}" >"$d/.omarchy/package.json"
}
commit_pkgs() { git -C "$pkgs" add -A && git -C "$pkgs" -c user.name=t -c user.email=t@t commit -q -m "$1"; }
pkgcommit() { git -C "$pkgs" log -1 --format=%H -- "pkgbuilds/$1"; }
# claim_id WORKER ARCH [STAT...] -> the id of the job claimed, empty for none
claim_id() { sed -n 's/^id=//p' < <("$job" claim "$@"); }
# upload_ok ID NAME VERSION [ARCH] -- a successful build's upload: log, package, buildsig
upload_ok() {
	local inc=$ARCHCI_HOME/incoming/$1
	echo log >"$inc/build.log"
	mkpkg "$inc" "$2" "$3" "${4:-x86_64}"
	: >"$inc/$2-$3-${4:-x86_64}.pkg.tar.zst.buildsig"
}

mkdir -p "$ARCHCI_HOME"/{queue/{pending,running,done,failed},built,logs,lock,incoming,repo}
pkgs=$tmp/pkgs
git -C "$tmp" init -q -b master "$pkgs"
mkpkgbuild linux 7.2.3.arch1-2
mkpkgbuild libsigc++ 2.12.2-1
mkpkgbuild acl 1:2.3.2-1
mkpkgbuild skipped 1-1 x86_64 '{"source": "local", "skip_build": true}'
commit_pkgs init
export ARCHCI_PKGBUILDS_URL=file://$pkgs
