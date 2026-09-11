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
: "${ARCHCI_PKGBUILDS_BRANCH:=master}"
: "${ARCHCI_PKGBUILDS_DIR:=pkgbuilds}"
# Name of the pacman repository the farm produces ($repo in the client's
# Server line, the database name, and the repo/<repo>/os/<arch> pool).
: "${ARCHCI_REPO:=omarchy}"
# Only build packages whose .omarchy/package.json "source" is listed
# (e.g. "arch" for those carried from Arch Linux). Empty: every package.
# ARCHCI_PKG_ALSO names packages built regardless of that filter.
: "${ARCHCI_PKG_SOURCES:=}"
: "${ARCHCI_PKG_ALSO:=}"
: "${ARCHCI_MAX_ATTEMPTS:=3}"
: "${ARCHCI_STALE_MINUTES:=30}"
: "${ARCHCI_RETRY_MINUTES:=180}"
: "${ARCHCI_RETRY_HOLD_MINUTES:=720}"
: "${ARCHCI_RELEASE_LAG_MINUTES:=10}"
: "${ARCHCI_DONE_KEEP_DAYS:=30}"
# Where systemd-journal-remote keeps the workers' journals (archci-top reads them).
: "${ARCHCI_REMOTE_JOURNAL:=/var/log/journal/remote}"
# R2 (or any rclone remote). Master writes unsigned packages to STAGING; the
# signer reads STAGING, signs, and writes the released repo to RELEASE. Both
# empty = the R2 hand-off is idle. See README "Signing".
: "${ARCHCI_R2_STAGING:=}"
: "${ARCHCI_R2_RELEASE:=}"
: "${ARCHCI_RCLONE_CONFIG:=/etc/archci/rclone.conf}"
# Master: the released repo's public URL, as clients use it (the master's
# rclone token need not read RELEASE). archci-signer-status reports the
# released databases' age and size from it. Empty = not reported.
: "${ARCHCI_RELEASE_URL:=}"
# --- signing (see README "Signing") -------------------------------------------
# Master holds NO key. Workers sign each package with a builder key (internal
# provenance); the signer droplet verifies that, adds the client-facing release
# signature, builds the database, and publishes the released repo.
# Worker: gpg home holding the builder secret key, and its key id/uid.
: "${ARCHCI_BUILDER_GNUPGHOME:=/etc/archci/builder-gnupg}"
: "${ARCHCI_BUILDER_KEY:=archci-builder}"
# Signer: gpg home with the release SECRET key (passphrase-protected, unlocked
# through gpg-agent) plus the authorized builder PUBLIC keys, and the key id.
: "${ARCHCI_RELEASE_GNUPGHOME:=/etc/archci/release-gnupg}"
: "${ARCHCI_RELEASE_KEY:=archci-release}"
: "${ARCHCI_BUILDER_KEYRING:=/etc/archci/builder-keyring}"
: "${ARCHCI_SIGNER_HOME:=/var/lib/archci-signer}"
# archci-sign-health warns when at least this many packages sit unsigned in staging.
: "${ARCHCI_STAGING_WARN:=20}"
# Packages archci-sign takes per pass (a minute apart): small, so what the
# farm stages next, its own release first, waits a pass and not a backlog.
: "${ARCHCI_SIGN_BATCH:=20}"
# How often archci-sign lists a release directory to prune what its database
# no longer names (superseded versions are deleted as they are replaced; the
# listing catches leftovers of interrupted passes).
: "${ARCHCI_SIGN_PRUNE_MINUTES:=60}"
: "${ARCHCI_MASTER:=archci@master}"
# Empty (set to "" in the config) disables journal streaming; hence = not :=.
# Journal streaming target: the master's journal-remote port through the ssh
# tunnel of archci-logging-remote.service (the master listens on loopback only).
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
# Pass --ignorearch to makepkg on a port arch (PKGBUILDs only list x86_64).
: "${ARCHCI_IGNOREARCH:=1}"
# PACKAGER stamped into every package (.PKGINFO / pacman -Si). Set to your identity.
: "${ARCHCI_PACKAGER:=archci build farm <archci@localhost>}"
: "${ARCHCI_CHROOT_UPDATE_MINUTES:=60}"
# A build whose output stops for this long is killed (a stuck test suite);
# 0 leaves only the unit's TimeoutStartSec. A fat-LTO link (mise, fish)
# is silent for well over half an hour, so not too low.
: "${ARCHCI_BUILD_MAX_IDLE_MINUTES:=90}"
: "${ARCHCI_IDLE_SLEEP:=60}"
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
# (cpu is what workers before 0.3.30 sent: cores, computed there)
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

archci_log() {
	printf '%s: %s\n' "${0##*/}" "$*" >&2
	# Commands invoked over ssh have no journal stream of their own; mirror them into it.
	if [[ -z ${JOURNAL_STREAM:-} ]] && command -v logger >/dev/null; then
		logger -t "${0##*/}" -- "$*" 2>/dev/null || true
	fi
}
archci_die() { archci_log "$@"; exit 1; }
archci_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Job ids look like "<prio>-<epoch>-<repo>,<pkgbase>,<version>,<arch>"; they
# double as file names, rsync targets and log paths, so they are validated
# strictly.
archci_valid_id()     { [[ $1 =~ ^[0-9]-[0-9]+-[a-z0-9-]+,[a-zA-Z0-9@._+-]+,[a-zA-Z0-9@._+:~-]+,[a-z0-9_]+$ ]]; }
archci_valid_worker() { [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ ]]; }
archci_valid_arch()   { [[ $1 =~ ^[a-z0-9_]{1,32}$ ]]; }
# Is ARCH one of ARCHCI_ARCHES?
archci_enabled_arch() { [[ " $ARCHCI_ARCHES " == *" $1 "* ]]; }
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

# archci_prune_cache DIR KEEP -- delete all but the KEEP newest versions of
# each package in the pacman cache DIR, with their signatures. A worker's
# caches grow by a version of everything it builds against; nothing else
# empties them. Versions are ordered as sort -V sees them.
archci_prune_cache() {
	local dir=$1 keep=$2 line
	(( keep > 0 )) && [[ -d $dir ]] || return 0
	# "<name>|<version>|<file>" per package file, newest version of a name first
	find "$dir" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' -printf '%f\n' |
		sed -En 's/^(.+)-([^-]+)-([^-]+)-([^-]+)\.pkg\.tar\.[a-z0-9]+$/\1|\2-\3|&/p' |
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
	job_id='' job_repo='' job_arch='' job_pkgbase='' job_version='' job_tag='' job_commit='' job_profile='' job_attempt=0 job_worker=''
	while IFS= read -r line || [[ -n $line ]]; do
		[[ $line =~ ^(id|repo|arch|pkgbase|version|tag|commit|profile|attempt|worker)=(.*)$ ]] || continue
		printf -v "job_${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]}"
	done <"$1"
	[[ -n $job_id && -n $job_repo && -n $job_arch && -n $job_pkgbase && -n $job_version && -n $job_commit ]]
}

# archci_worker_stats -> "load=<1 min> mem=<used %> disk=<chroots %> cpus=<n>",
# what a worker sends with each heartbeat (archci-job heartbeat validates the
# tokens and keeps them in the job file).
# archci_version -> the installed archci version: VERSION (archci-cli writes
# it), else what pacman knows, else the checkout's git describe.
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
# scope exists; nothing while there is neither. Raw figures: the CPU time the
# build used since the previous sample and the wall time that took (archci
# top divides them into cores), memory in MiB, the build tree in KiB. The container's processes live in a scope of nspawn's own,
# devtools.slice/*/makechrootpkg-<pkg>.build.<pid>.scope, named after the
# makechrootpkg process, which itself sits in the build unit's cgroup; the
# scope's cgroup accounts CPU and memory for the whole build. cpu is the cores
# used on average since the previous call (JOBDIR/cpu.prev); build is the
# chroot copy's /build directory (archci-build writes the copy to
# JOBDIR/copydir), where makepkg extracts and compiles.
archci_job_stats() {
	local jobdir=$1 unit=$2 ucg pid cg='' copydir usage now prev_usage prev_now cpu mem peak build phase=''
	[[ -r $jobdir/phase ]] && phase=$(<"$jobdir/phase") && [[ $phase =~ ^[A-Za-z0-9._-]{1,8}$ ]] || phase=''
	ucg=$(systemctl show -p ControlGroup --value "$unit" 2>/dev/null)
	[[ -n $ucg && -f /sys/fs/cgroup$ucg/cgroup.procs ]] || { [[ -n $phase ]] && echo "phase=$phase"; return 0; }
	while read -r pid; do
		for cg in /sys/fs/cgroup/devtools.slice/*/makechrootpkg-*."$pid".scope; do
			[[ -d $cg ]] && break 2
		done
		cg=''
	done <"/sys/fs/cgroup$ucg/cgroup.procs"
	[[ -n $cg ]] || { [[ -n $phase ]] && echo "phase=$phase"; return 0; }
	{
		usage=$(awk '/^usage_usec/ { print $2 }' "$cg/cpu.stat" 2>/dev/null) || return 0
		now=$(date +%s%6N)
		# CPU time used since the previous sample, and the wall time between
		# the samples; on the first, since the scope started (systemd's
		# monotonic clock against /proc/uptime, both in us), or since the job
		# started (JOBDIR/started, written by archci-worker) when the scope is
		# too young to have a start time yet
		local cpu_us='' cpu_dt=''
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
		[[ -f $jobdir/copydir ]] && copydir=$(<"$jobdir/copydir") && build=$(du -sk "$copydir/build" 2>/dev/null | cut -f1)
		printf '%s%srss=%s peak=%s build=%s\n' "${phase:+phase=$phase }" "${cpu_us:+cpu_us=$cpu_us cpu_dt=$cpu_dt }" "$mem" "$peak" "${build:-0}"
	}
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
# to DIR into the master's repo/<repo>/os/<arch>/ directories (the pool that
# archci-stage moves to R2 staging), each with its builder signature
# (<pkg>.buildsig) alongside for the signer to verify. The master holds no key
# and builds no database. A package goes under the arch in its file name; a
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
	local -A dest=()   # package -> arches to pool it for
	for p in "${pkgs[@]}"; do
		base=${p##*/}; parch=${base%.pkg.tar.zst}; parch=${parch##*-}
		if [[ $parch == any ]]; then dest[$p]=$ARCHCI_ARCHES
		elif archci_enabled_arch "$parch" && archci_can_build "$parch" "$jobarch"; then dest[$p]=$parch
		else archci_log "refusing $base: arch $parch is not $jobarch or enabled"; return 1
		fi
	done
	(
		exec 8>"$ARCHCI_HOME/lock/repo.lock"
		flock 8
		for p in "${pkgs[@]}"; do
			base=${p##*/}
			local r=$repo
			[[ $base == *-debug-"$version"-*.pkg.tar.zst ]] && r=$repo-debug
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
# (Arch builds core with it too). archci-pkgs decides per package from
# .omarchy/package.json arch_repo and a lib32- prefix; this is the fallback
# for a job file without a profile, keyed by its repo name.
archci_profile() {
	case $1 in
		multilib*) echo multilib ;;
		*) echo extra ;;
	esac
}
