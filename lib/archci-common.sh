# shellcheck shell=bash
# archci-common.sh -- shared helpers, sourced by every archci bash script.

ARCHCI_CONF=${ARCHCI_CONF:-/etc/archci/archci.conf}
# Layout, identical in the source tree and under /usr/lib/archci:
#   lib/     this file and archci.rb, shared
#   master/  scan, queue (archci-job), ssh shell, publish, status
#   worker/  archci-worker loop and archci-build
ARCHCI_ROOT=$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")
ARCHCI_MASTER_DIR=$ARCHCI_ROOT/master

# Load KEY=value lines from the config file. Values already present in the
# environment win, so tests and one-off runs can override the file.
archci_load_conf() {
	local line key
	[[ -r $ARCHCI_CONF ]] || return 0
	while IFS= read -r line || [[ -n $line ]]; do
		[[ $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || continue
		key=${BASH_REMATCH[1]}
		[[ -v $key ]] && continue
		eval "$key=${BASH_REMATCH[2]}"
	done <"$ARCHCI_CONF"
}
archci_load_conf

: "${ARCHCI_HOME:=/var/lib/archci}"
: "${ARCHCI_ARCH:=$(uname -m)}"
# Master: architectures workers may claim jobs for (worker claims carry their
# arch). Upstream releases only x86_64 (plus "any"), so every arch here builds
# the x86_64 release list; a port arch needs its own workers and an
# arch/<arch>/makepkg.conf on them. ARCHCI_ANY_ARCH is the arch whose workers
# build the arch-independent ("any") packages, pooled for every arch.
: "${ARCHCI_ARCHES:=$ARCHCI_ARCH}"
: "${ARCHCI_ANY_ARCH:=${ARCHCI_ARCHES%% *}}"
# The PKGBUILD repository: one git repository holding every package the farm
# builds as <ARCHCI_PKGBUILDS_DIR>/<name>/PKGBUILD plus .omarchy/package.json
# (the omarchy-pkgs layout). Its branch is the release list: a package is
# outstanding when the version its PKGBUILD declares is not the one last
# built. Switching to another fork is this one URL.
: "${ARCHCI_PKGBUILDS_URL:=https://github.com/hegjon/omarchy-pkgs.git}"
: "${ARCHCI_PKGBUILDS_BRANCH:=core+extra}"
: "${ARCHCI_PKGBUILDS_DIR:=pkgbuilds}"
# Name of the pacman repository the farm produces ($repo in the client's
# Server line, the database name, and the repo/<repo>/os/<arch> pool).
: "${ARCHCI_REPO:=omarchy}"
# Only build packages whose .omarchy/package.json "source" is listed
# (e.g. "arch" for those carried from Arch Linux), and, with
# ARCHCI_PKG_REPOS, only those of the listed Arch repositories (core,
# extra, multilib, from package.json arch_repo). Empty: every package.
# ARCHCI_PKG_ALSO names packages built regardless of both filters.
: "${ARCHCI_PKG_SOURCES:=}"
: "${ARCHCI_PKG_REPOS:=}"
: "${ARCHCI_PKG_ALSO:=}"
: "${ARCHCI_MAX_ATTEMPTS:=3}"
: "${ARCHCI_STALE_MINUTES:=30}"
: "${ARCHCI_RETRY_MINUTES:=180}"
: "${ARCHCI_RETRY_HOLD_MINUTES:=720}"
: "${ARCHCI_RELEASE_LAG_MINUTES:=20}"
# where the master keeps what it can rebuild (the index cache)
: "${ARCHCI_CACHE_DIR:=/var/cache/archci}"
# where archci-pkgindex reads a directory's cached index line from: the cache file
# (file) or the PKGBUILD's extended attributes (xattr); both are written
: "${ARCHCI_INDEX_CACHE:=file}"
# Sources. "src" is a job arch: the sourcer claims src jobs the way a
# worker claims builds, fetches every source the package's PKGBUILD names
# into a source package (<pkgbase>-<version>-<sha256>.src.tar.zst), builder-signs it
# and hands it in like a build's packages; it is pooled under
# <repo>/os/src, release-signed and published beside the arches, and a
# build claim names it (sources=) once archci-publish has listed it as
# released (ARCHCI_RELEASE_LAG_MINUTES after the build without a listing); a worker with ARCHCI_RELEASE_URL takes it from
# there, checks the release signature, and fetches nothing upstream.
# ARCHCI_SOURCES_REQUIRED=1 holds a build until that is so; 0 lets a build
# fetch upstream meanwhile. The sourcer's state: ARCHCI_SOURCER_HOME (the
# PKGBUILD mirror, SRCDEST, jobs), and the time one fetch may take.
: "${ARCHCI_SOURCER_HOME:=/var/lib/archci-sourcer}"
: "${ARCHCI_SOURCES_REQUIRED:=0}"
: "${ARCHCI_SOURCER_TIMEOUT_MINUTES:=30}"
: "${ARCHCI_DONE_KEEP_DAYS:=30}"
# Where systemd-journal-remote keeps the workers' journals (archci-top reads them).
: "${ARCHCI_REMOTE_JOURNAL:=/var/lib/archci/journal}"
: "${ARCHCI_LOG_MAX_LINES:=50000}"
# The release: the master publishes the signed pool to this rclone remote
# (e.g. "r2:archci-test2"), the repository clients use. Empty = index only,
# nothing published (a farm without a release, the tests). See README
# "Signing".
: "${ARCHCI_R2_RELEASE:=}"
: "${ARCHCI_RCLONE_CONFIG:=/etc/archci/rclone.conf}"
# The released repo's public URL, as clients use it (workers' chroots install
# from it and fetch source packages by it). Empty = the mirrors only.
: "${ARCHCI_RELEASE_URL:=}"
# Master: every ARCHCI_PUBLISH_RECONCILE_MINUTES archci-publish lists each
# release directory and deletes what its database does not name (superseded
# versions go the pass that replaces them; the listing catches leftovers of
# an interrupted pass).
: "${ARCHCI_PUBLISH_RECONCILE_MINUTES:=60}"
# --- signing (see README "Signing") -------------------------------------------
# Master holds NO signing key. Workers sign each package with a builder key
# (internal provenance); the signer host fetches what waits from the master,
# verifies that, adds the client-facing release signature and returns it; the
# master verifies the returned signature with the release PUBLIC key, indexes
# and publishes.
# Worker: gpg home holding the builder secret key, and its key id/uid.
: "${ARCHCI_BUILDER_GNUPGHOME:=/etc/archci/builder-gnupg}"
: "${ARCHCI_BUILDER_KEY:=archci-builder}"
# Master: the release public key (an armored export from the signer), which
# it verifies returned signatures with and publishes as release.pub.
: "${ARCHCI_RELEASE_PUBKEY:=/etc/archci/release.pub}"
# Signer: gpg home with the release SECRET key (passphrase-protected, unlocked
# through gpg-agent) plus the authorized builder PUBLIC keys, and the key id;
# its ssh key to the master (made on first run, authorized there with
# `archci authorize --signer`) and its working directory.
: "${ARCHCI_RELEASE_GNUPGHOME:=/etc/archci/release-gnupg}"
: "${ARCHCI_RELEASE_KEY:=archci-release}"
: "${ARCHCI_BUILDER_KEYRING:=/etc/archci/builder-keyring}"
: "${ARCHCI_SIGNER_KEY:=/etc/archci/signer_key}"
: "${ARCHCI_SIGNER_HOME:=/var/lib/archci-signer}"
# archci-sign-health warns when at least this many files wait unsigned on the master.
: "${ARCHCI_UNSIGNED_WARN:=${ARCHCI_STAGING_WARN:-20}}"
# Files archci-sign takes per pass (a minute apart): small, so what the farm
# pools next, its own release first, waits a pass and not a backlog.
: "${ARCHCI_SIGN_BATCH:=20}"
: "${ARCHCI_MASTER:=archci@master}"
# Empty (set to "" in the config) disables journal streaming; hence = not :=.
# Journal streaming target: the master's journal-remote port through the ssh
# tunnel of archci-logging-tunnel.service (the master listens on loopback only).
: "${ARCHCI_JOURNAL_URL=http://127.0.0.1:19533}"
: "${ARCHCI_WORKER_KEY:=/etc/archci/worker_key}"
: "${ARCHCI_WORKER_HOME:=/var/lib/archci-worker}"
: "${ARCHCI_BUILD_USER:=archci}"
: "${ARCHCI_CHROOTS:=/var/lib/archbuild}"
: "${ARCHCI_MAKEPKG_ARGS=}"
# Keyservers the fingerprints a PKGBUILD names (validpgpkeys) are refreshed
# from before its sources are verified; empty for none.
: "${ARCHCI_KEYSERVERS:=hkps://keys.openpgp.org hkps://keyserver.ubuntu.com}"
# Skip check() when building another arch than the machine's (qemu user-mode
# emulation), where test suites fail on the emulation more than on the package.
: "${ARCHCI_EMULATED_NOCHECK:=1}"
# Environment every build sees (VAR=value pairs, no spaces in a value),
# written as a makepkg.conf drop-in into the clean chroot.
: "${ARCHCI_BUILD_ENV:=CMAKE_POLICY_VERSION_MINIMUM=3.5}"
# Versions of each package kept in the package caches the builds use (the
# rest is deleted at the hourly chroot update); 0 keeps everything.
: "${ARCHCI_CACHE_KEEP:=1}"
# the worker's own source cache: files not used for this many days are deleted
: "${ARCHCI_SRCDEST_KEEP_DAYS:=7}"
# Builds run off the network (archci_firewall: the build's container
# reaches nothing, loopback included; its dependencies are installed in a
# container of its own first, with the network, and its sources come from
# the source package or were fetched on the host). 0: every container
# keeps the network, as before. package.json "network": "loopback" lets a
# package's build talk to itself (a test suite with a server), "full" (or
# true) gives it the network; both are the package's own, approved by hand.
# ARCHCI_BUILD_LOOPBACK=1 lets every build on this host reach loopback (the
# lenient default while the packages that need it are being found).
: "${ARCHCI_BUILD_OFFLINE:=1}"
: "${ARCHCI_BUILD_LOOPBACK:=0}"
# Pass --ignorearch to makepkg on a port arch (PKGBUILDs only list x86_64).
: "${ARCHCI_IGNOREARCH:=1}"
# PACKAGER stamped into every package (.PKGINFO / pacman -Si). Set to your identity.
: "${ARCHCI_PACKAGER:=archci build farm <archci@localhost>}"
: "${ARCHCI_CHROOT_UPDATE_MINUTES:=10}"
# A build whose output stops for this long is killed (a stuck test suite);
# 0 leaves only the unit's TimeoutStartSec. A fat-LTO link (mise, fish)
# is silent for well over half an hour, so not too low.
: "${ARCHCI_BUILD_MAX_IDLE_MINUTES:=90}"
: "${ARCHCI_IDLE_SLEEP:=30}"
# Between tries at delivering a finished build while the master is unreachable.
: "${ARCHCI_DELIVERY_RETRY_SECONDS:=30}"
: "${ARCHCI_HEARTBEAT_SECONDS:=60}"
export "${!ARCHCI_@}"

# The heartbeat's stats, in one place (archci.rb keeps the same two lists):
# the host's, sent by archci_worker_stats, and the job's, by archci_job_stats.
# The master keeps them with the job (archci-job heartbeat) for the UIs.
# (stat names must not be job fields: a heartbeat replaces lines of these
# names in the job file, so a stat called version would eat the package's)
ARCHCI_HOST_STATS='load mem disk cpus vendor archci'
ARCHCI_JOB_STATS='cpu_us cpu_dt rss peak build phase'
archci_stats_re() { local s="$ARCHCI_HOST_STATS $ARCHCI_JOB_STATS"; printf '%s' "${s// /|}"; }

# Master: the PKGBUILD repository clone and the package index over it.
ARCHCI_PKGBUILDS_CLONE=$ARCHCI_HOME/pkgbuilds
ARCHCI_PKGBUILDS_INDEX=$ARCHCI_HOME/pkgbuilds.index

# Master queue. A job is one small key=value file that moves between these.
Q_PENDING=$ARCHCI_HOME/queue/pending
Q_RUNNING=$ARCHCI_HOME/queue/running
Q_DONE=$ARCHCI_HOME/queue/done
Q_FAILED=$ARCHCI_HOME/queue/failed

# archci_log MESSAGE... -- to stderr (a unit's journal), and, for a command
# invoked over ssh (no journal stream of its own: archci-job, archci-shell),
# mirrored into the journal by logger; with ARCHCI_LOG_JOB set (the job a
# claim, heartbeat or report is about) the entry carries it as the
# ARCHCI_JOB field, so `journalctl ARCHCI_JOB=<id>` on the master is the
# job's trace: its claim, heartbeats, report and pooling. (Not a setting:
# set per command by archci-job.)
archci_log() {
	printf '%s: %s\n' "${0##*/}" "$*" >&2
	if [[ -z ${JOURNAL_STREAM:-} ]] && command -v logger >/dev/null; then
		if [[ -n ${ARCHCI_LOG_JOB:-} ]]; then
			printf 'MESSAGE=%s\nPRIORITY=6\nSYSLOG_IDENTIFIER=%s\nARCHCI_JOB=%s\n' "$*" "${0##*/}" "$ARCHCI_LOG_JOB" | logger --journald 2>/dev/null || true
		else
			logger -t "${0##*/}" -- "$*" 2>/dev/null || true
		fi
	fi
}
archci_die() { archci_log "$@"; archci_journal_close 2>/dev/null || true; exit 1; }
archci_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Job ids look like "<prio>-<epoch>-<repo>,<pkgbase>,<version>,<arch>"; they
# double as file names, rsync targets and log paths, so they are validated
# strictly.
archci_valid_id()     { [[ $1 =~ ^[0-9]-[0-9]+-[a-z0-9-]+,[a-zA-Z0-9@._+-]+,[a-zA-Z0-9@._+:~-]+,[a-z0-9_]+$ ]]; }
archci_valid_worker() { [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ ]]; }
archci_valid_arch()   { [[ $1 =~ ^[a-z0-9_]{1,32}$ ]]; }
# Is ARCH one of ARCHCI_ARCHES, or src (source packages, the sourcer's jobs)?
archci_enabled_arch() { [[ " $ARCHCI_ARCHES " == *" $1 "* || $1 == src ]]; }
# May a worker of arch WORKER_ARCH build a job of arch JOB_ARCH?
archci_can_build()    { [[ $2 == "$1" || ( $2 == any && $1 == "$ARCHCI_ANY_ARCH" ) ]]; }

# archci_arch_conf ARCH FILE DEFAULT -> the chroot config FILE for ARCH: from
# /etc/archci/ARCH/ if present, else arch/ARCH/ in the archci tree, else DEFAULT.
archci_arch_conf() {
	local d
	for d in /etc/archci/$1 "$ARCHCI_ROOT/arch/$1"; do
		[[ -f $d/$2 ]] && { printf '%s\n' "$d/$2"; return 0; }
	done
	printf '%s\n' "$3"
}

# --- structured records in the journal ----------------------------------
# archci's own lines in a build's log (the header, the slice markers, each
# package signed, the end) carry journal fields, so nothing downstream reads
# them out of the text: ARCHCI_JOB, ARCHCI_ATTEMPT, ARCHCI_EVENT=start|slice|
# signed|finish and the event's facts (ARCHCI_RC, ARCHCI_SLICE, ARCHCI_PACKAGE,
# ...). The MESSAGE is the same human line as ever. They go through the
# journal's native socket from a coprocess (ruby) that lives as long as the script
# (archci_journal_open), so journald attributes them to the unit (a
# short-lived `logger` exits before journald reads its cgroup, and its entry
# has no unit); they are sent where no build output is in flight (before the
# container starts, between its two runs, after it exits), so they keep
# their place among the unit's stdout lines. Off a unit (no JOURNAL_STREAM,
# the tests) or without the socket, archci_record prints the line instead.
archci_journal_open() {
	[[ -n ${JOURNAL_STREAM:-} && -S /run/systemd/journal/socket ]] || return 1
	command -v ruby >/dev/null || return 1
	# records on stdin, one field per line, a blank line ends a record; each
	# one datagram on the journal's native socket
	# shellcheck disable=SC2016  # $stdin is ruby's
	coproc ARCHCI_JOURNAL { ruby -e '
		require "socket"
		s = Socket.new(:UNIX, :DGRAM)
		s.connect(Socket.pack_sockaddr_un("/run/systemd/journal/socket"))
		rec = +""
		$stdin.each_line do |l|
		  if l == "\n" then s.send(rec, 0) unless rec.empty?; rec = +"" else rec << l end
		end
		s.send(rec, 0) unless rec.empty?' 2>/dev/null; }
	# one fd of our own to the coprocess's stdin; the coproc's array fd is
	# closed so that closing ours is the EOF it waits for
	exec {ARCHCI_JOURNAL_FD}>&"${ARCHCI_JOURNAL[1]}"
	eval "exec ${ARCHCI_JOURNAL[1]}>&-"
	return 0
}
# archci_journal_close -- EOF to the coprocess and wait for it to have sent
# everything: a script must do this before it exits, or the unit's stop may
# kill the sender with the last record unsent
archci_journal_close() {
	[[ -n ${ARCHCI_JOURNAL_FD:-} ]] || return 0
	exec {ARCHCI_JOURNAL_FD}>&-
	unset ARCHCI_JOURNAL_FD
	wait "${ARCHCI_JOURNAL_PID:-}" 2>/dev/null || true
}
# archci_record MESSAGE [FIELD=VALUE...] -- one record (a single line, no
# newlines in a value) with its fields, through the coprocess when open,
# else as a line on stdout
archci_record() {
	local msg=$1; shift
	if [[ -n ${ARCHCI_JOURNAL_FD:-} ]]; then
		{ printf 'MESSAGE=%s\nPRIORITY=6\nSYSLOG_IDENTIFIER=%s\n' "$msg" "${0##*/}"; (( $# )) && printf '%s\n' "$@"; printf '\n'; } >&"$ARCHCI_JOURNAL_FD"
	else
		printf '%s\n' "$msg"
	fi
}

# --- content-addressed names ---------------------------------------------
# Every built artifact carries the sha256 of its own bytes in its name:
# <name>-<ver>-<rel>-<arch>-<sha256>.pkg.tar.zst and
# <pkgbase>-<version>-<sha256>.src.tar.zst. A retry, a second build of the
# same version and a fresh rebuild never collide, and every published object
# is immutable under its name. The worker and the sourcer name their outputs
# so before signing them (the builder and release signatures follow the
# final name); the master gives an upload that lacks the hash one at ingest
# (an older worker), so the pool always holds hashed names.
# archci_artifact_stem NAME -> NAME (a path or a file name) without its extension
archci_artifact_stem() {
	local n=${1##*/}
	n=${n%.pkg.tar.zst}; n=${n%.src.tar.zst}; n=${n%.src.tar.gz}
	printf '%s\n' "$n"
}
# archci_artifact_ext NAME -> the extension, with its leading dot
archci_artifact_ext() { local n=${1##*/}; printf '%s\n' "${n#"$(archci_artifact_stem "$n")"}"; }
# archci_hashed NAME -> 0 when the stem ends in -<64 hex>
archci_hashed() { [[ $(archci_artifact_stem "$1") =~ -[0-9a-f]{64}$ ]]; }
# archci_unhashed_stem NAME -> the stem without a trailing -<sha256>, so
# <name>-<ver>-<rel>-<arch> or <pkgbase>-<version>, hashed or not
archci_unhashed_stem() {
	local s; s=$(archci_artifact_stem "$1")
	[[ $s =~ ^(.*)-[0-9a-f]{64}$ ]] && s=${BASH_REMATCH[1]}
	printf '%s\n' "$s"
}
# archci_hash_rename FILE -- FILE renamed to its hashed name (as it is when
# it has one), and its .buildsig and .sig beside it renamed with it; prints
# the new path
archci_hash_rename() {
	local f=$1 dir stem ext sha new s
	if archci_hashed "$f"; then printf '%s\n' "$f"; return 0; fi
	dir=${f%/*}; [[ $dir == "$f" ]] && dir=.
	stem=$(archci_artifact_stem "$f"); ext=$(archci_artifact_ext "$f")
	sha=$(sha256sum -- "$f") || return 1
	new=$dir/$stem-${sha%% *}$ext
	mv -- "$f" "$new" || return 1
	for s in buildsig sig; do [[ -f $f.$s ]] && mv -- "$f.$s" "$new.$s"; done
	printf '%s\n' "$new"
}
# archci_pkginfo FILE FIELD -> FIELD's value from the package's .PKGINFO (the
# package itself says what it is; its file name is not parsed)
archci_pkginfo() { bsdtar -xOf "$1" .PKGINFO 2>/dev/null | sed -n "s/^$2 = //p" | head -1; }

# archci_prune_cache DIR KEEP -- delete all but the KEEP newest versions of
# each package in the pacman cache DIR, with their signatures. A worker's
# caches grow by a version of everything it builds against; nothing else
# empties them. Versions are ordered as sort -V sees them.
archci_prune_cache() {
	local dir=$1 keep=$2 line
	(( keep > 0 )) && [[ -d $dir ]] || return 0
	# "<name>|<version>|<file>" per package file, newest version of a name first
	find "$dir" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' -printf '%f\n' |
		sed -En -e 's/^(.+)-([^-]+)-([^-]+)-([^-]+)-[0-9a-f]{64}\.pkg\.tar\.[a-z0-9]+$/\1|\2-\3|&/p' -e t \
		    -e 's/^(.+)-([^-]+)-([^-]+)-([^-]+)\.pkg\.tar\.[a-z0-9]+$/\1|\2-\3|&/p' |
		sort -t'|' -k1,1 -k2,2rV |
		awk -F'|' -v keep="$keep" '{ if (++n[$1] > keep) print $3 }' |
	while IFS= read -r line; do
		rm -f "$dir/$line" "$dir/$line.sig"
	done
}

# archci_chroot_pacconf SRC DST REPO ARCH -- DST is the chroot pacman.conf SRC
# with the farm's own repository ([REPO], the job's, at ARCHCI_RELEASE_URL)
# inserted above the first repository, so builds resolve dependencies from
# what the farm has built before falling back to the mirrors (a repository
# listed first wins for a name regardless of version), and with a package
# cache of its own: the farm's packages share file names with the mirrors'
# (and a port's) but not bytes, so a shared cache fails their checksums.
# SRC that already names the repository is copied as is. Signatures are
# checked: the host's pacman keyring, which the chroot inherits, must trust
# the release key.
archci_chroot_pacconf() {
	local src=$1 dst=$2 repo=$3 arch=$4
	mkdir -p "${dst%/*}"
	if grep -q "^\[$repo\]" "$src"; then
		cp "$src" "$dst.new"
	else
		awk -v repo="$repo" -v url="$ARCHCI_RELEASE_URL" -v cache="/var/cache/archci/pkg/$repo-$arch/" '
			/^#?CacheDir *=/ { next }
			$0 == "[options]" { print; print "# a cache of this repository'"'"'s own (archci-build): the farm'"'"'s packages share"; print "# file names with the mirrors'"'"' but not bytes"; print "CacheDir = " cache; next }
			!done && /^\[[^]]+\]/ {
				print "# The farm'"'"'s own repository first (archci-build, ARCHCI_RELEASE_URL):"
				print "# what it has built is what dependencies resolve to."
				print "[" repo "]"
				print "SigLevel = Required DatabaseOptional"
				print "Server = " url "/$repo/os/$arch"
				print ""
				done = 1
			}
			{ print }' "$src" >"$dst.new"
	fi
	mv "$dst.new" "$dst"
}

# archci_read_job FILE -> job_id job_repo job_arch job_pkgbase job_version
#                         job_commit job_profile job_attempt job_worker
# pkgbase is the package directory under ARCHCI_PKGBUILDS_DIR (its PKGBUILD's
# own pkgbase may differ for a split package); commit is the PKGBUILD
# repository commit the build is pinned to. (tag is accepted from old files.)
archci_read_job() {
	local line
	job_id='' job_repo='' job_arch='' job_pkgbase='' job_version='' job_tag='' job_commit='' job_profile='' job_attempt=0 job_worker='' job_created='' job_sources='' job_network=''
	while IFS= read -r line || [[ -n $line ]]; do
		[[ $line =~ ^(id|repo|arch|pkgbase|version|tag|commit|profile|attempt|worker|created|sources|network)=(.*)$ ]] || continue
		printf -v "job_${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]}"
	done <"$1"
	[[ -n $job_id && -n $job_repo && -n $job_arch && -n $job_pkgbase && -n $job_version && -n $job_commit ]]
}

# archci_worker_stats -> "load=<1 min> mem=<used %> disk=<chroots %> cpus=<n>",
# what a worker sends with each heartbeat (archci-job heartbeat validates the
# tokens and keeps them in the job file).
# archci_version -> the installed archci version: VERSION (the archci package
# writes it), else what pacman knows, else the checkout's git describe.
archci_version() {
	local v
	if [[ -r $ARCHCI_ROOT/VERSION ]]; then cat "$ARCHCI_ROOT/VERSION"
	elif [[ ! -d $ARCHCI_ROOT/.git ]] && v=$(pacman -Q archci 2>/dev/null); then echo "${v#* }"
	else git -C "$ARCHCI_ROOT" describe --tags --always --dirty 2>/dev/null | sed "s/^v//" || echo unknown
	fi
}

# archci_worker_stats [DIR] -> the host stats: load, memory and the disk DIR
# (the chroots by default; the master measures its state directory) is on.
archci_worker_stats() {
	local dir=${1:-$ARCHCI_CHROOTS} load total avail used=0 disk vendor version
	read -r load _ </proc/loadavg
	# memory and chroot disk in use, in percent with one decimal
	total=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
	avail=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
	(( total > 0 )) && used=$(awk -v t="$total" -v a="$avail" 'BEGIN { printf "%.1f", (t - a) * 100 / t }')
	disk=$(df --output=used,size "$dir" 2>/dev/null | awk 'NR == 2 && $2 > 0 { printf "%.1f", $1 * 100 / $2 }')
	# who made the machine (DMI: "DigitalOcean", "AsrockRack"...), for the hosts table
	vendor=$(tr -c 'A-Za-z0-9.-' '-' </sys/class/dmi/id/sys_vendor 2>/dev/null | sed -E 's/-+$//; s/^-+//' | cut -c1-32)
	# the archci this worker runs, for the hosts table (only if it fits a stat token)
	version=$(archci_version); [[ $version =~ ^[A-Za-z0-9./-]{1,32}$ ]] || version=''
	printf 'load=%s mem=%s disk=%s cpus=%s%s%s\n' "$load" "$used" "${disk:-0}" "$(nproc)" "${vendor:+ vendor=$vendor}" "${version:+ archci=$version}"
}

# archci_phase_filter FILE -- pass the build's output through, and on each of
# makepkg's and makechrootpkg's marker lines ("==> Starting build()...",
# "==> Installing missing dependencies...") write the phase it opens, in at
# most eight characters, to FILE (renamed into place). archci-build runs its
# build through it; the worker sends FILE with every heartbeat, so the master
# knows the phase without reading the build's journal (a chatty build outlives
# the journal's memory of its own start).
archci_phase_filter() {
	awk -v f="$1" '
		{ print; fflush() }
		/^==> / {
			p = ""
			if ($0 ~ /^==> Starting [A-Za-z0-9_-]+\(\)/) { w = $3; sub(/\(\).*/, "", w); p = (w ~ /^package_/) ? "package" : substr(w, 1, 8) }
			else if ($0 ~ /^==> Making package/) p = "start"
			else if ($0 ~ /^==> Installing missing/) p = "deps"
			else if ($0 ~ /^==> Retrieving/) p = "download"
			else if ($0 ~ /^==> Validating/) p = "sums"
			else if ($0 ~ /^==> Verifying/) p = "verify"
			else if ($0 ~ /^==> Extracting/) p = "extract"
			else if ($0 ~ /^==> Creating/) p = "compress"
			else if ($0 ~ /^==> Updating/) p = "update"
			else if ($0 ~ /^==> Synchronizing/) p = "sync"
			if (p != "") { printf "%s\n", p > (f ".tmp"); close(f ".tmp"); system("mv -f \"" f ".tmp\" \"" f "\"") }
		}'
}

# archci_job_stats JOBDIR UNIT -> "phase=<phase> cpu_us=<us> cpu_dt=<us> rss=<MiB> peak=<MiB> build=<KiB>"
# for the build UNIT (archci-build@...) running from JOBDIR: the phase as soon
# as archci_phase_filter has written JOBDIR/phase, the rest once the build's
# container exists; nothing while there is neither. Raw figures: the CPU
# time the build used since the previous sample and the wall time that took
# (archci top divides them into cores), memory in MiB, the build tree in
# KiB. The container's processes live in a scope of nspawn's own, named
# after the machine archci-build gave it (JOBDIR/machine, see
# archci_container_cgroup); the scope's cgroup accounts CPU and memory for
# the whole build. build is the chroot copy's /build directory
# (archci-build writes the copy to JOBDIR/copydir), where makepkg extracts
# and compiles.
archci_job_stats() {
	local jobdir=$1 cg='' copydir build phase='' machine=''
	[[ -r $jobdir/phase ]] && phase=$(<"$jobdir/phase") && [[ $phase =~ ^[A-Za-z0-9._-]{1,8}$ ]] || phase=''
	[[ -r $jobdir/machine ]] && machine=$(<"$jobdir/machine")
	[[ -n $machine ]] && cg=$(archci_container_cgroup "$machine")
	[[ -n $cg ]] || { [[ -n $phase ]] && echo "phase=$phase"; return 0; }
	build=''
	[[ -f $jobdir/copydir ]] && copydir=$(<"$jobdir/copydir") && build=$copydir/build
	archci_cgroup_stats "$cg" "$jobdir" "$build" "${phase:+phase=$phase }"
}

# archci_cgroup_stats CG JOBDIR DIR [PREFIX] -- the job stats of the cgroup
# CG (a path under /sys/fs/cgroup; a scope's): the CPU time used since the
# previous sample and the wall time between the samples (JOBDIR/cpu.prev;
# on the first, since the scope started, by systemd's monotonic clock
# against /proc/uptime, or since the job started, JOBDIR/started, when the
# scope is too young to have a start time yet), memory now and at its peak
# in MiB, and the size of DIR in KiB (the build tree, the fetched sources),
# after PREFIX on the one line; nothing while the cgroup has no cpu.stat.
archci_cgroup_stats() {
	local cg=$1 jobdir=$2 dir=$3 prefix=${4:-} usage now prev_usage prev_now mem peak build cpu_us='' cpu_dt=''
	usage=$(awk '/^usage_usec/ { print $2 }' "$cg/cpu.stat" 2>/dev/null) || return 0
	now=$(date +%s%6N)
	if [[ -f $jobdir/cpu.prev ]]; then
		read -r prev_usage prev_now <"$jobdir/cpu.prev"
		(( now > prev_now )) && cpu_us=$((usage - prev_usage)) cpu_dt=$((now - prev_now))
	else
		local started up
		started=$(systemctl show -p ActiveEnterTimestampMonotonic --value "${cg##*/}" 2>/dev/null || true)
		up=$(awk '{ printf "%d", $1 * 1000000 }' /proc/uptime)
		if [[ $started =~ ^[1-9][0-9]*$ ]] && (( up > started )); then
			cpu_us=$usage cpu_dt=$((up - started))
		elif [[ -f $jobdir/started ]] && started=$(<"$jobdir/started") && [[ $started =~ ^[0-9]+$ ]] && (( now > started )); then
			cpu_us=$usage cpu_dt=$((now - started))
		fi
	fi
	printf '%s %s\n' "$usage" "$now" >"$jobdir/cpu.prev"
	mem=$(( $(<"$cg/memory.current") / 1048576 ))
	peak=$(( $(cat "$cg/memory.peak" 2>/dev/null || echo 0) / 1048576 ))
	build=0
	[[ -n $dir ]] && build=$(du -sk "$dir" 2>/dev/null | cut -f1)
	printf '%s%srss=%s peak=%s build=%s\n' "$prefix" "${cpu_us:+cpu_us=$cpu_us cpu_dt=$cpu_dt }" "$mem" "$peak" "${build:-0}"
}

# archci_watchdog SECONDS -- COMMAND... : run COMMAND with its output through a
# pipe (systemd-nspawn drops a stdout that is the journal socket, so the lines
# makepkg prints inside the chroot only reach the journal this way) and kill
# it, with its whole process group, when it prints nothing for SECONDS: a test
# suite that hangs otherwise holds the worker until the unit's TimeoutStartSec.
# Returns COMMAND's status, 124 when killed. SECONDS 0 means no idle limit.
archci_watchdog() {
	local idle=$1; shift
	[[ ${1:-} == -- ]] && shift
	local fifo pid fd line r killed=0 rc=0
	local -a topt=()
	(( idle > 0 )) && topt=(-t "$idle")
	fifo=$(mktemp -u); mkfifo -m 600 "$fifo"
	setsid "$@" >"$fifo" 2>&1 &
	pid=$!
	exec {fd}<"$fifo"
	rm -f "$fifo"
	while :; do
		if IFS= read -r "${topt[@]}" line <&"$fd"; then printf '%s\n' "$line"; continue; else r=$?; fi
		if (( r > 128 )); then
			echo "==> no output for $idle s, killing the build"
			kill -TERM -- "-$pid" 2>/dev/null || true
			sleep 15
			kill -KILL -- "-$pid" 2>/dev/null || true
			killed=1
			continue      # drain what is left until the pipe closes
		fi
		[[ -n $line ]] && printf '%s\n' "$line"
		break
	done
	exec {fd}<&-
	wait "$pid" || rc=$?
	(( killed )) && rc=124
	return "$rc"
}

# archci_pool DIR REPO JOBARCH VERSION -- pool the packages a worker uploaded
# to DIR into the master's repo/<repo>/os/<arch>/ directories (the pool the
# signer fetches from and archci-publish releases), each with its builder
# signature (<pkg>.buildsig) alongside for the signer to verify. The master
# holds no signing key. A package goes under the arch in its file name; a
# debug package under <repo>-debug; an arch-independent (-any) package into
# every enabled arch, since pacman fetches every package from the client's own
# $repo/os/$arch. Every file is checked before any is copied, so a package of
# an arch the job could not have built (or none) refuses the whole upload
# and nothing reaches the pool. Prints the number of packages pooled.
archci_pool() {
	local dir=$1 repo=$2 jobarch=$3 version=$4 p base parch a
	local -a pkgs
	shopt -s nullglob; pkgs=("$dir"/*.pkg.tar.zst); shopt -u nullglob
	(( ${#pkgs[@]} )) || { archci_log "no packages in $dir"; return 1; }
	local -A dest=() debug=()   # package -> arches to pool it for; -> 1 for a debug package
	for p in "${pkgs[@]}"; do
		base=${p##*/}
		# what the package says it is, not what its name says
		parch=$(archci_pkginfo "$p" arch)
		[[ -n $parch ]] || { archci_log "refusing $base: no .PKGINFO"; return 1; }
		[[ $(archci_pkginfo "$p" pkgname) == *-debug ]] && debug[$p]=1
		if [[ $parch == any ]]; then dest[$p]=$ARCHCI_ARCHES
		elif archci_enabled_arch "$parch" && archci_can_build "$parch" "$jobarch"; then dest[$p]=$parch
		else archci_log "refusing $base: arch $parch is not $jobarch or enabled"; return 1
		fi
	done
	# the hashed name, for an upload that lacks it (an older worker)
	local -a hashed=()
	for p in "${pkgs[@]}"; do
		hashed+=("$(archci_hash_rename "$p")") || { archci_log "could not hash ${p##*/}"; return 1; }
		[[ ${hashed[-1]} == "$p" ]] || { dest[${hashed[-1]}]=${dest[$p]}; [[ -n ${debug[$p]:-} ]] && debug[${hashed[-1]}]=1; }
	done
	pkgs=("${hashed[@]}")
	(
		exec 8>"$ARCHCI_HOME/lock/repo.lock"
		flock 8
		for p in "${pkgs[@]}"; do
			base=${p##*/}
			local r=$repo
			[[ -n ${debug[$p]:-} ]] && r=$repo-debug
			for a in ${dest[$p]}; do
				mkdir -p "$ARCHCI_HOME/repo/$r/os/$a"
				cp --reflink=auto "$p" "$ARCHCI_HOME/repo/$r/os/$a/$base" || exit 1
				[[ -f $p.buildsig ]] && cp "$p.buildsig" "$ARCHCI_HOME/repo/$r/os/$a/$base.buildsig"
			done
			rm -f "$p" "$p.buildsig"
		done
	) || return 1
	printf '%s\n' "${#pkgs[@]}"
}

# devtools build profile (name of pacman.conf.d/<profile>.conf) for a package:
# multilib packages need the multilib one, everything else builds with extra
# (Arch builds core with it too). archci-pkgindex decides per package from
# .omarchy/package.json arch_repo and a lib32- prefix; this is the fallback
# for a job file without a profile, keyed by its repo name.
archci_profile() {
	case $1 in
		multilib*) echo multilib ;;
		*) echo extra ;;
	esac
}

# archci_pkg_wanted PKGBASE -- is the package one the farm builds
# (ARCHCI_PKG_SOURCES, ARCHCI_PKG_REPOS, ARCHCI_PKG_ALSO; archci.rb's
# candidates), by the package index (read once)? A package the index
# does not have is not wanted. The claim asks before handing out a queued
# job, so a filter set later holds the retries too.
declare -A _archci_pkg_source=() _archci_pkg_repo=()
_archci_pkg_index_read=0
archci_pkg_wanted() {
	local name source repo origin
	if (( ! _archci_pkg_index_read )); then
		_archci_pkg_index_read=1
		while read -r name _ _ _ _ source _ repo _; do
			[[ $name == \#* || -z $name ]] && continue
			_archci_pkg_source[$name]=$source
			_archci_pkg_repo[$name]=$repo
		done <"$ARCHCI_PKGBUILDS_INDEX" 2>/dev/null
	fi
	source=${_archci_pkg_source[$1]:-}
	[[ -n $source ]] || return 1
	[[ " $ARCHCI_PKG_ALSO " == *" $1 "* ]] && return 0
	[[ -z $ARCHCI_PKG_SOURCES || " $ARCHCI_PKG_SOURCES " == *" $source "* ]] || return 1
	if [[ $source == arch ]]; then origin=${_archci_pkg_repo[$1]:-}; [[ $origin == - || -z $origin ]] && origin=arch
	else origin=$source
	fi
	[[ -z $ARCHCI_PKG_REPOS || " $ARCHCI_PKG_REPOS " == *" $origin "* ]]
}

# --- vendored dependencies -------------------------------------------------
# A PKGBUILD that fetches a language ecosystem's packages in prepare()
# (Arch's convention: cargo fetch --locked, go mod download, npm ci, ...)
# needs the network at build time. The sourcer captures that fetch in its
# chroot: makepkg -o runs prepare() with the ecosystem's cache directed into
# vendor/<kind>/ (archci_vendor_env capture), which goes into the source
# package; the worker replays it offline: the same cache, and the ecosystem
# told to fetch nothing (archci_vendor_env replay). Kinds: rust (cargo), go
# (the module cache), npm (npm's cache; yarn, pnpm and bun keep their own
# and are best effort), pip (pip's cache: its index pages are served from
# it offline only while fresh; best effort) and maven (maven's local
# repository with --offline on replay, and gradle's user home with an init
# script that sets its offline flag, archci_vendor_replay_files). A package
# whose fetch the capture cannot serve builds with the network through
# package.json "network": true.
# archci_vendor_kinds PKGBUILD -> the kinds the PKGBUILD fetches, one per line
archci_vendor_kinds() {
	local f=$1
	grep -qE '(^|[^a-z])cargo (fetch|vendor)( |$)' "$f" && echo rust
	grep -qE '(^|[^a-z])go mod (download|vendor)( |$)' "$f" && echo go
	grep -qE '(^|[^a-z])(npm (ci|install)|yarn install|pnpm install|bun install)( |$)' "$f" && echo npm
	grep -qE '(^|[^a-z])pip (download|install)( |$)' "$f" && echo pip
	grep -qE '(^|[^a-z])(mvn|gradle)( |$)' "$f" && echo maven
	return 0
}
# archci_vendor_supported KIND -> can the kind be captured and replayed?
ARCHCI_VENDOR_KINDS='rust go npm pip maven'
archci_vendor_supported() { [[ " $ARCHCI_VENDOR_KINDS " == *" $1 "* ]]; }
# archci_vendor_env KIND capture|replay DIR -> the environment for the kind's
# tools, KEY=VALUE per line: capture directs the fetch into DIR/<kind>,
# replay points the build at it and, where the tool has a switch for it,
# forbids the network (the firewall does the rest).
archci_vendor_env() {
	local kind=$1 phase=$2 dir=$3
	case $kind:$phase in
		rust:capture) printf 'CARGO_HOME=%s/rust\n' "$dir" ;;
		rust:replay)  printf 'CARGO_HOME=%s/rust\nCARGO_NET_OFFLINE=true\n' "$dir" ;;
		go:capture)   printf 'GOMODCACHE=%s/go\nGOFLAGS=-mod=mod\n' "$dir" ;;
		go:replay)    printf 'GOMODCACHE=%s/go\nGOFLAGS=-mod=mod\nGOPROXY=off\n' "$dir" ;;
		npm:capture)  printf 'npm_config_cache=%s/npm\nYARN_CACHE_FOLDER=%s/yarn\n' "$dir" "$dir" ;;
		npm:replay)   printf 'npm_config_cache=%s/npm\nnpm_config_offline=true\nYARN_CACHE_FOLDER=%s/yarn\n' "$dir" "$dir" ;;
		pip:capture)  printf 'PIP_CACHE_DIR=%s/pip\n' "$dir" ;;
		pip:replay)   printf 'PIP_CACHE_DIR=%s/pip\n' "$dir" ;;
		maven:capture) printf 'MAVEN_OPTS=-Dmaven.repo.local=%s/maven\nGRADLE_USER_HOME=%s/gradle\n' "$dir" "$dir" ;;
		maven:replay)  printf 'MAVEN_OPTS=-Dmaven.repo.local=%s/maven\nMAVEN_ARGS=--offline\nGRADLE_USER_HOME=%s/gradle\n' "$dir" "$dir" ;;
		*) ;;
	esac
}
# archci_vendor_replay_files KIND DIR -- what a replay needs written into
# DIR/<kind> beyond the environment: gradle's offline flag has no
# environment switch, so an init script in its user home sets it (gradle
# runs every init.d/*.gradle there, for every build)
archci_vendor_replay_files() {
	case $1 in
		maven)
			mkdir -p "$2/maven/gradle/init.d"
			printf '// written by archci-build: the build has no network\ngradle.startParameter.offline = true\n' >"$2/maven/gradle/init.d/archci-offline.gradle" ;;
		*) ;;
	esac
}
# the source package's compression, by its extension: .src.tar.zst (the
# sourcer's, zstd's default level) or .src.tar.gz (an older one)
_srcpkg_unpack() { case $1 in *.zst) zstd -dcq -- "$1" ;; *) gzip -dc -- "$1" ;; esac; }
_srcpkg_pack() { case $1 in *.zst) zstd -cq -T0 -- ;; *) gzip -c ;; esac; }
# archci_srcpkg_add_vendor SRCPKG PKGBASE DIR -- put DIR into the source
# package (a plain tar, compressed, its entries under PKGBASE/) as
# PKGBASE/vendor/, root's, in place
archci_srcpkg_add_vendor() {
	local srcpkg=$1 pkgbase=$2 dir=$3 tarball=$1.tar
	_srcpkg_unpack "$srcpkg" >"$tarball" || return 1
	tar -rf "$tarball" -C "$(dirname "$dir")" --owner=0 --group=0 --transform="s|^$(basename "$dir")|$pkgbase/vendor|" "$(basename "$dir")" || return 1
	_srcpkg_pack "$srcpkg" <"$tarball" >"$srcpkg.tmp" && mv "$srcpkg.tmp" "$srcpkg" && rm -f "$tarball"
}

# archci_srcpkg_add_file SRCPKG PKGBASE FILE DEST -- put FILE into the source
# package as PKGBASE/DEST, root's, in place (as add_vendor does for a tree).
archci_srcpkg_add_file() {
	local srcpkg=$1 pkgbase=$2 file=$3 destname=$4 tarball=$1.tar
	_srcpkg_unpack "$srcpkg" >"$tarball" || return 1
	tar -rf "$tarball" -C "$(dirname "$file")" --owner=0 --group=0 --transform="s|^$(basename "$file")|$pkgbase/$destname|" "$(basename "$file")" || return 1
	_srcpkg_pack "$srcpkg" <"$tarball" >"$srcpkg.tmp" && mv "$srcpkg.tmp" "$srcpkg" && rm -f "$tarball"
}

# _sbom_emit PURL NAME VERSION [ALG HEX] -- one CycloneDX component, preceded
# by a comma except the first (the _sbom_first caller variable). Identifiers
# are package-registry values (safe charset), so no JSON escaping is needed.
_sbom_emit() {
	local purl=$1 name=$2 ver=$3 alg=${4:-} hex=${5:-} hashes=''
	[[ -n $alg && -n $hex ]] && hashes=$(printf ', "hashes": [{ "alg": "%s", "content": "%s" }]' "$alg" "$hex")
	(( _sbom_first )) && _sbom_first=0 || printf ','
	printf '\n    { "type": "library", "bom-ref": "%s", "name": "%s", "version": "%s", "purl": "%s"%s }' \
		"$purl" "$name" "$ver" "$purl" "$hashes"
}

# _go_unescape ESCAPED -> the real module path (go's cache escapes an uppercase
# letter as !<lowercase>, so !b -> B)
_go_unescape() {
	local s=$1 out='' next
	while [[ $s == *'!'* ]]; do out+=${s%%!*}; s=${s#*!}; next=${s:0:1}; out+=${next^^}; s=${s:1}; done
	printf '%s%s' "$out" "$s"
}

# archci_sbom VENDORDIR PKGBASE PKGVER -- a CycloneDX 1.5 SBOM (JSON on stdout)
# of the dependencies vendored under VENDORDIR: rust crates (pkg:cargo, from
# the .crate archives), go modules (pkg:golang, from the module cache zips) and
# npm packages (pkg:npm, from the cacache index), each a component with its PURL
# and a hash; the package itself is the top component. The sourcer writes it
# into the source package.
archci_sbom() {
	local dir=$1 pkgbase=$2 pkgver=$3 uuid f base name ver sum rel mod key integ json b64 hex purl
	local _sbom_first=1
	uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)
	printf '{\n  "bomFormat": "CycloneDX",\n  "specVersion": "1.5",\n'
	[[ -n $uuid ]] && printf '  "serialNumber": "urn:uuid:%s",\n' "$uuid"
	printf '  "version": 1,\n  "metadata": {\n'
	printf '    "timestamp": "%s",\n' "$(archci_now)"
	printf '    "tools": [{ "vendor": "archci", "name": "archci-sourcer", "version": "%s" }],\n' "$(archci_version)"
	printf '    "component": { "type": "application", "bom-ref": "%s@%s", "name": "%s", "version": "%s", "purl": "pkg:generic/%s@%s" }\n' \
		"$pkgbase" "$pkgver" "$pkgbase" "$pkgver" "$pkgbase" "$pkgver"
	printf '  },\n  "components": ['

	# rust: one .crate archive per crate
	for f in "$dir"/rust/registry/cache/*/*.crate; do
		[[ -e $f ]] || continue
		base=${f##*/}; base=${base%.crate}
		[[ $base =~ ^(.+)-([0-9].*)$ ]] || continue
		sum=$(sha256sum "$f" | cut -d' ' -f1)
		_sbom_emit "pkg:cargo/${BASH_REMATCH[1]}@${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" SHA-256 "$sum"
	done

	# go: cache/download/<escaped module>/@v/<version>.zip
	while IFS= read -r f; do
		[[ -n $f ]] || continue
		rel=${f#"$dir"/go/cache/download/}
		[[ $rel == *"/@v/"*.zip ]] || continue
		ver=${rel##*/@v/}; ver=${ver%.zip}
		mod=$(_go_unescape "${rel%%/@v/*}")
		sum=$(sha256sum "$f" | cut -d' ' -f1)
		_sbom_emit "pkg:golang/$mod@$ver" "$mod" "$ver" SHA-256 "$sum"
	done < <(find "$dir/go/cache/download" -type f -name '*.zip' -path '*/@v/*' 2>/dev/null | sort)

	# npm: the cacache index (index-v5) maps each tarball URL to its integrity
	while IFS= read -r json; do
		[[ $json == \{* ]] || continue
		key=$(jq -r '.key // empty' <<<"$json" 2>/dev/null) || continue
		[[ $key == *"/-/"*.tgz ]] || continue
		base=${key##*/-/}; base=${base%.tgz}
		[[ $base =~ ^(.+)-([0-9].*)$ ]] || continue
		ver=${BASH_REMATCH[2]}
		name=${key%%/-/*}; name=${name##*://*/}   # drop scheme://host/ , keep the package path
		name=${name//%2f//}; name=${name//%2F//}; name=${name//%40/@}
		[[ -n $name ]] || continue
		integ=$(jq -r '.integrity // empty' <<<"$json" 2>/dev/null)
		hex=''
		[[ $integ == sha512-* ]] && { b64=${integ#sha512-}; hex=$(printf '%s' "$b64" | base64 -d 2>/dev/null | od -An -v -tx1 | tr -d ' \n'); }
		purl="pkg:npm/${name/@/%40}@$ver"
		if [[ -n $hex ]]; then _sbom_emit "$purl" "$name" "$ver" SHA-512 "$hex"; else _sbom_emit "$purl" "$name" "$ver"; fi
	done < <(find "$dir/npm/_cacache/index-v5" -type f -exec cat {} \; 2>/dev/null | cut -f2-)

	printf '\n  ]\n}\n'
}

# --- containers: what the worker's builds and the sourcer's fetches share -
# Both enter a copy of a clean chroot with arch-nspawn (devtools'), in a
# slice of archci's own: archci-online for what may reach the network (a
# build's dependency install, the sourcer's fetch, a build with the network
# exemption), archci-loopback for a build that may talk to itself (a test
# suite with a server of its own; package.json "network": "loopback"), and
# archci-offline for a build itself, which archci_firewall keeps off every
# network, loopback included. nspawn names the container's scope
# <machine>.<pid>.scope under the slice.
# archci_container_cgroup MACHINE -> the scope's cgroup path, empty for none
# (nspawn names the scope <machine>.scope; a machine name is a host's one
# container at a time, so archci-build makes it unique per worker instance)
archci_container_cgroup() {
	local c
	for c in /sys/fs/cgroup/archci.slice/*/"$1".scope /sys/fs/cgroup/archci.slice/*/"$1".*.scope; do [[ -d $c ]] && { printf '%s\n' "$c"; return 0; }; done
	return 0
}
# archci_container_stop MACHINE -- stop the container's scope, if it runs
archci_container_stop() {
	local cg
	cg=$(archci_container_cgroup "$1")
	[[ -n $cg ]] && systemctl stop "${cg##*/}" 2>/dev/null || true
}
# archci_machine_name PREFIX NAME -> a machine name (a hostname: 64 characters
# of letters, digits and dashes, so x86_64 becomes x86-64) for the container
# of NAME; the prefix must make it unique among a host's containers (nspawn
# refuses a second of a name)
archci_machine_name() { printf '%s-%s' "$1" "$2" | tr -c 'A-Za-z0-9-' '-' | cut -c1-64; }

# archci_chroot_copy ROOT COPY -- a fresh copy of the clean chroot ROOT at
# COPY: a btrfs snapshot where the filesystem allows, an rsync otherwise
# (devtools' archroot.sh helpers, sourced by the caller). 1 on failure.
archci_chroot_copy() {
	local root=$1 copy=$2
	if is_btrfs "${root%/*}" && is_subvolume "$root" && ! mountpoint -q "$copy"; then
		subvolume_delete_recursive "$copy" || return 1
		rm -rf --one-file-system "$copy"
		btrfs subvolume snapshot "$root" "$copy" >/dev/null || return 1
	else
		mkdir -p "$copy"
		rsync -a --delete -q -W -x "$root/" "$copy" || return 1
	fi
	touch "$copy"
}
# archci_chroot_prepare COPY UID GID [PACKAGER] -- the copy made ready for
# makepkg as makechrootpkg does it: the build user with the ids given
# (builduser: what it writes to the bound directories is the host user's),
# the directories makepkg is told to use (/build, /startdir, /srcdest,
# /pkgdest, /srcpkgdest, /logdest, bound by the caller), sudo for pacman
# (makepkg -s), git's safe.directory
archci_chroot_prepare() {
	local copy=$1 uid=$2 gid=$3 packager=${4:-}
	sed -e '/^builduser:/d' -i "$copy"/etc/{passwd,shadow,group}
	printf 'builduser:x:%d:\n' "$gid" >>"$copy/etc/group"
	printf 'builduser:x:%d:%d:builduser:/build:/bin/bash\n' "$uid" "$gid" >>"$copy/etc/passwd"
	printf 'builduser:!!:%d::::::\n' "$(( $(date -u +%s) / 86400 ))" >>"$copy/etc/shadow"
	rm -rf "$copy/build"
	install -d -o "$uid" -g "$gid" "$copy"/{build,startdir,srcdest,pkgdest,srcpkgdest,logdest}
	sed -e '/^\(BUILDDIR\|SRCDEST\|PKGDEST\|SRCPKGDEST\|LOGDEST\|PACKAGER\)=/d' -i "$copy/etc/makepkg.conf"
	printf '%s\n' BUILDDIR=/build SRCDEST=/srcdest PKGDEST=/pkgdest SRCPKGDEST=/srcpkgdest LOGDEST=/logdest >>"$copy/etc/makepkg.conf"
	[[ -n $packager ]] && printf 'PACKAGER=%s\n' "${packager@Q}" >>"$copy/etc/makepkg.conf"
	printf 'builduser ALL = NOPASSWD: /usr/bin/pacman\n' >"$copy/etc/sudoers.d/builduser-pacman"
	chmod 440 "$copy/etc/sudoers.d/builduser-pacman"
	mkdir -p "$copy/etc/makepkg.d"
	printf '[safe]\n\tdirectory = *\n' | tee "$copy/etc/gitconfig" >"$copy/etc/makepkg.d/gitconfig"
}
# The tmpfs every container gets on /tmp (makepkg's mktemp needs it writable)
ARCHCI_CONTAINER_TMP='--tmpfs=/tmp:mode=1777,strictatime,nodev,nosuid,size=50%'

# archci_firewall -- the nftables table that keeps a build's container off
# the network: a socket of a cgroup under archci.slice/archci-offline.slice
# (--slice=archci-offline) reaches nothing, loopback included; one under
# archci-loopback.slice reaches loopback and nothing else; both rejected,
# so tools fail at once; archci-online is untouched. The table is archci's
# own, beside whatever else the host runs; idempotent (rewritten at every
# build). nft resolves the cgroup paths when the rules are loaded, so the
# slices are started first (they exist from then on). Needs root and
# nftables; 1, with the reason on stderr, when the table cannot be set up.
archci_firewall() {
	command -v nft >/dev/null || { echo "nft is not installed" >&2; return 1; }
	systemctl start archci-offline.slice archci-loopback.slice archci-online.slice 2>/dev/null ||
		mkdir -p /sys/fs/cgroup/archci.slice/archci-{offline,loopback,online}.slice 2>/dev/null || true
	nft -f - <<-'NFT'
		table inet archci
		delete table inet archci
		table inet archci {
			chain output {
				type filter hook output priority filter; policy accept;
				socket cgroupv2 level 2 "archci.slice/archci-offline.slice" counter reject
				socket cgroupv2 level 2 "archci.slice/archci-loopback.slice" oifname != "lo" counter reject
			}
		}
	NFT
}

# --- the job protocol over ssh: what the worker and the sourcer share -----
# archci_master CMD... -- run a job-protocol command (claim, heartbeat,
# report: archci-shell on the master) with the worker key; -n: never stdin.
ARCHCI_SSH_OPTS=(-i "$ARCHCI_WORKER_KEY" -o BatchMode=yes -o ConnectTimeout=30
	-o ServerAliveInterval=30 -o ServerAliveCountMax=4
	-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/etc/archci/known_hosts)
archci_master() { ssh -n "${ARCHCI_SSH_OPTS[@]}" "$ARCHCI_MASTER" "$@"; }

# archci_claim WORKER ARCH FILE [K=V...] -- one claim, the host stats sent
# along (they keep the master's hosts table current while idle). 0: a job,
# read into the job_* variables and left in FILE. 1: nothing to do, or the
# master is unreachable (said once per outage, not once a minute all
# weekend) or sent nonsense; the caller sleeps ARCHCI_IDLE_SLEEP and asks
# again.
_archci_down=0
archci_claim() {
	local worker=$1 arch=$2 file=$3
	shift 3
	if ! archci_master claim "$worker" "$arch" "$@" >"$file"; then
		(( _archci_down )) || archci_log "master unreachable, retrying every ${ARCHCI_IDLE_SLEEP}s"
		_archci_down=1
		rm -f "$file"
		return 1
	fi
	(( _archci_down )) && archci_log "master reachable again"
	_archci_down=0
	[[ -s $file ]] || { rm -f "$file"; return 1; }
	archci_read_job "$file" && return 0
	archci_log "master sent an unreadable job, ignoring"
	rm -f "$file"
	return 1
}

# archci_deliver ID DIR STATUS WORKER -- upload DIR, the job's results, into
# the master's incoming/ID/ and report STATUS as WORKER (a job requeued and
# claimed elsewhere meanwhile refuses it). While the master is unreachable
# (a reboot, a night, a weekend) the results are kept and retried every
# ARCHCI_DELIVERY_RETRY_SECONDS for as long as it takes; a heartbeat first
# keeps the master's housekeeping from requeueing the job as stale when it
# comes back. Only ssh failures (exit 255) mean "unreachable": a heartbeat
# or report the master itself refuses says the job is no longer ours (taken
# by housekeeping, or re-claimed elsewhere), and only then are the results
# dropped. 0: reported; 1: dropped.
archci_deliver() {
	local id=$1 dir=$2 status=$3 who=$4 uploaded=0 try=0 rc
	while true; do
		(( ++try ))
		rc=0; archci_master heartbeat "$id" "worker=$who" phase=upload || rc=$?
		if (( rc == 255 )); then
			(( try == 1 )) && archci_log "master unreachable, keeping $id's results until it is back"
			sleep "$ARCHCI_DELIVERY_RETRY_SECONDS"; continue
		elif (( rc )); then
			archci_log "$id is no longer ours; dropping its results"; return 1
		fi
		if (( ! uploaded )); then
			if rsync -a --timeout=300 -e "ssh ${ARCHCI_SSH_OPTS[*]}" "$dir/" "$ARCHCI_MASTER:$id/"; then
				uploaded=1
			else
				archci_log "upload of $id failed (try $try)"
				sleep "$ARCHCI_DELIVERY_RETRY_SECONDS"; continue
			fi
		fi
		rc=0; archci_master report "$id" "$status" "$who" || rc=$?
		if (( rc == 0 )); then
			(( try > 1 )) && archci_log "$id delivered after $try tries"
			return 0
		fi
		(( rc == 255 )) || { archci_log "the master refused the report for $id; dropping it"; return 1; }
		archci_log "could not report $id (try $try)"
		sleep "$ARCHCI_DELIVERY_RETRY_SECONDS"
	done
}
