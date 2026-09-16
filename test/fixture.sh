# shellcheck shell=bash
# fixture.sh -- what the master-side tests share: a throwaway ARCHCI_HOME, a
# fake PKGBUILD repository in the omarchy-pkgs layout (pkgbuilds/<name>/PKGBUILD
# plus .omarchy/package.json) with four packages, paths to the scripts and
# helpers for fake packages and claims. Runs without network or root. Source it
# after setting $here (the test directory); it sets $tmp and removes it on exit.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export ARCHCI_CONF=/dev/null ARCHCI_HOME=$tmp/home ARCHCI_CACHE_DIR=$tmp/cache ARCHCI_REPO=omarchy ARCHCI_ARCH=x86_64
export ARCHCI_PKGBUILDS_BRANCH=master ARCHCI_MAX_ATTEMPTS=2 ARCHCI_STALE_MINUTES=0 ARCHCI_RETRY_MINUTES=0 ARCHCI_RELEASE_LAG_MINUTES=0 JOURNAL_STREAM=1
master=$here/../master
failed=$master/archci-failed
job=$master/archci-job
scan=$master/archci-scan
next=$master/archci-next
housekeeping=$master/archci-housekeeping
top=$master/archci-top
fail() { echo "FAIL: $*" >&2; exit 1; }
# mkpkg DIR NAME VERSION [ARCH] -- smallest thing repo-add accepts as a package,
# named as a worker names it: NAME-VERSION-ARCH-<sha256>.pkg.tar.zst; prints the path
mkpkg() {
	local d=$tmp/mkpkg arch=${4:-x86_64} f=$1/$2-$3-${4:-x86_64}.pkg.tar.zst sha; rm -rf "$d"; mkdir -p "$d"
	printf 'pkgname = %s\npkgbase = %s\npkgver = %s\npkgdesc = fake\nurl = x\nbuilddate = 1\npackager = t\nsize = 0\narch = %s\n' \
		"$2" "${2%-debug}" "$3" "$arch" >"$d/.PKGINFO"
	bsdtar -C "$d" -cf - .PKGINFO | zstd -q >"$f"
	sha=$(sha256sum "$f"); mv "$f" "${f%.pkg.tar.zst}-${sha%% *}.pkg.tar.zst"
	printf '%s\n' "${f%.pkg.tar.zst}-${sha%% *}.pkg.tar.zst"
}
# pkgfile DIR NAME VERSION [ARCH] -- the one NAME-VERSION-ARCH-<sha256>.pkg.tar.zst in DIR
pkgfile() {
	local -a m; shopt -s nullglob; m=("$1/$2-$3-${4:-x86_64}-"*.pkg.tar.zst); shopt -u nullglob
	(( ${#m[@]} == 1 )) || { echo "pkgfile: ${#m[@]} matches for $2-$3-${4:-x86_64} in $1" >&2; return 1; }
	printf '%s\n' "${m[0]}"
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
# The workers' journal on the master (ARCHCI_REMOTE_JOURNAL), where every
# job's log is read from: a journal directory of the test's own, written with
# systemd-journal-remote from journal export format (no root needed).
#   journal_add HOST UNIT LINE...   one entry per line, now, as UNIT on HOST
#                                   (SYSLOG_IDENTIFIER is the unit's name; a
#                                   line starting with "stderr:" is logged at
#                                   priority 3, as a unit's stderr is, else 6)
#   build_unit PKGBASE VERSION ARCH ATTEMPT -> a build's unit name (archci-worker's rule)
export ARCHCI_REMOTE_JOURNAL=$tmp/journal
journal_add() {
	local host=$1 unit=$2 ts f=$tmp/journal.export
	shift 2
	ts=$(date +%s%6N)   # microseconds: each call's entries come after the last call's
	: >"$f"
	local pri
	for line; do
		pri=6; [[ $line == stderr:* ]] && { pri=3; line=${line#stderr:}; }
		printf '__REALTIME_TIMESTAMP=%s\n__MONOTONIC_TIMESTAMP=%s\n_BOOT_ID=%s\n_HOSTNAME=%s\n_SYSTEMD_UNIT=%s\nSYSLOG_IDENTIFIER=%s\nPRIORITY=%s\nMESSAGE=%s\n\n' \
			"$ts" "$ts" 0123456789abcdef0123456789abcdef "$host" "$unit" "${unit%%[@.]*}" "$pri" "$line" >>"$f"
		(( ts += 1 ))
	done
	mkdir -p "$ARCHCI_REMOTE_JOURNAL"
	/usr/lib/systemd/systemd-journal-remote --split-mode=none -o "$ARCHCI_REMOTE_JOURNAL/test.journal" "$f" >/dev/null 2>&1 \
		|| fail "systemd-journal-remote could not write the test journal (systemd)"
}
build_unit() {
	local u="$ARCHCI_REPO-$1-$2-$3-a$4"
	printf 'archci-build@%s.service\n' "${u//[^A-Za-z0-9:_.-]/_}"
}
# claim_id WORKER ARCH [STAT...] -> the id of the job claimed, empty for none
claim_id() { sed -n 's/^id=//p' < <("$job" claim "$@"); }
owner() { sed -n 's/^worker=//p' "$ARCHCI_HOME/queue/running/$1.job"; }   # the worker a running job is claimed by
# upload_ok ID NAME VERSION [ARCH] -- a successful build's upload: log, package, buildsig
upload_ok() {
	local inc=$ARCHCI_HOME/incoming/$1 f
	f=$(mkpkg "$inc" "$2" "$3" "${4:-x86_64}")
	: >"$f.buildsig"
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
