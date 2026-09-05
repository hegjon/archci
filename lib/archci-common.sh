# shellcheck shell=bash
# archci-common.sh -- shared helpers, sourced by every archci bash script.

ARCHCI_CONF=${ARCHCI_CONF:-/etc/archci/archci.conf}
# Layout, identical in the source tree and under /usr/local/lib/archci:
#   lib/     this file and archci.rb, shared
#   master/  scan, queue (archci-job), ssh shell, publish, status
#   worker/  archci-worker loop and archci-build
ARCHCI_ROOT=$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")
ARCHCI_MASTER_DIR=$ARCHCI_ROOT/master
ARCHCI_WORKER_DIR=$ARCHCI_ROOT/worker

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
: "${ARCHCI_ARCH:=x86_64}"
: "${ARCHCI_REPOS:=core extra}"
: "${ARCHCI_STATE_URL:=https://gitlab.archlinux.org/archlinux/packaging/state.git}"
: "${ARCHCI_PKGBUILD_URL:=https://gitlab.archlinux.org/archlinux/packaging/packages}"
: "${ARCHCI_MAX_ATTEMPTS:=3}"
: "${ARCHCI_STALE_MINUTES:=30}"
: "${ARCHCI_RETRY_MINUTES:=180}"
: "${ARCHCI_DONE_KEEP_DAYS:=30}"
# R2 (or any rclone remote). Master writes unsigned packages to STAGING; the
# signer reads STAGING, signs, and writes the released repo to RELEASE. Both
# empty = the R2 hand-off is idle. See README "Signing".
: "${ARCHCI_R2_STAGING:=}"
: "${ARCHCI_R2_RELEASE:=}"
: "${ARCHCI_RCLONE_CONFIG:=/etc/archci/rclone.conf}"
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
: "${ARCHCI_SNAPSHOTS:=5}"
: "${ARCHCI_MASTER:=archci@master}"
: "${ARCHCI_JOURNAL_URL:=http://${ARCHCI_MASTER#*@}:19532}"
: "${ARCHCI_WORKER_KEY:=/etc/archci/worker_key}"
: "${ARCHCI_WORKER_HOME:=/var/lib/archci-worker}"
: "${ARCHCI_BUILD_USER:=archci}"
: "${ARCHCI_CHROOTS:=/var/lib/archbuild}"
: "${ARCHCI_MAKEPKG_ARGS:=--skippgpcheck}"
: "${ARCHCI_CHROOT_UPDATE_MINUTES:=60}"
: "${ARCHCI_IDLE_SLEEP:=60}"
: "${ARCHCI_HEARTBEAT_SECONDS:=300}"
export "${!ARCHCI_@}"

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

# Job ids look like "<prio>-<epoch>-<repo>,<pkgbase>,<version>"; they double as
# file names, rsync targets and log paths, so they are validated strictly.
archci_valid_id()     { [[ $1 =~ ^[0-9]-[0-9]+-[a-z0-9-]+,[a-zA-Z0-9@._+-]+,[a-zA-Z0-9@._+:~-]+$ ]]; }
archci_valid_worker() { [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ ]]; }

# archci_read_job FILE -> job_id job_repo job_arch job_pkgbase job_version
#                         job_tag job_commit job_attempt job_worker
archci_read_job() {
	local line
	job_id= job_repo= job_arch= job_pkgbase= job_version= job_tag= job_commit= job_attempt=0 job_worker=
	while IFS= read -r line || [[ -n $line ]]; do
		[[ $line =~ ^(id|repo|arch|pkgbase|version|tag|commit|attempt|worker)=(.*)$ ]] || continue
		printf -v "job_${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]}"
	done <"$1"
	[[ -n $job_id && -n $job_repo && -n $job_arch && -n $job_pkgbase && -n $job_version && -n $job_commit ]]
}

# Packaging repo -> devtools build profile (name of pacman.conf.d/<profile>.conf).
# core has no profile of its own; Arch builds core packages with the extra one.
archci_profile() {
	case $1 in
		core) echo extra ;;
		*) echo "$1" ;;
	esac
}

# pkgbase -> GitLab project path. Same rules as devtools' gitlab_project_name_to_path.
archci_gitlab_path() {
	printf '%s' "$1" | sed -E \
		-e 's/([a-zA-Z0-9]+)\+([a-zA-Z]+)/\1-\2/g' \
		-e 's/\+/plus/g' \
		-e 's/[^a-zA-Z0-9_\-\.]/-/g' \
		-e 's/[_\-]{2,}/-/g' \
		-e 's/^tree$/unix-tree/'
}
