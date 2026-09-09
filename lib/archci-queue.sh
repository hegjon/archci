# shellcheck shell=bash
# archci-queue.sh -- the master's job queue, sourced by archci-job (the
# commands) and master/internal/archci-housekeeping (the timer's pass).
# Requires archci-common.sh.
#
# Jobs are files; moving them between queue/{pending,running,done,failed} is
# the whole state machine. The backlog is never stored: pending/ only holds
# manual enqueues and retries. Everything that touches the queue takes queue.lock.

lock_queue() {
	exec 9>"$ARCHCI_HOME/lock/queue.lock"
	flock 9
}

# Move FILE to DIR, dropping bookkeeping fields and appending EXTRA lines. A
# job that ends (done/, failed/) keeps its last heartbeat stats and when that
# beat arrived (the file's mtime): the host's last known state for the UIs.
rewrite_job() {
	local file=$1 dest=$2 tmp beat=() drop
	drop="worker|claimed|status|finished|final|heartbeat|$(archci_stats_re)"
	shift 2
	if [[ $dest == "$Q_DONE"/* || $dest == "$Q_FAILED"/* ]]; then
		drop='worker|claimed|status|finished|final|heartbeat'
		grep -q '^load=' "$file" && beat=("heartbeat=$(date -u -r "$file" +%FT%TZ)")
	fi
	tmp=$dest.tmp
	{
		grep -Ev "^($drop)=" "$file"
		printf '%s\n' "$@" "${beat[@]}"
	} >"$tmp"
	mv "$tmp" "$dest"
	[[ $file == "$dest" ]] || rm -f "$file"
}

set_attempt() {  # set_attempt FILE N  (in place)
	local file=$1 n=$2 tmp=$1.tmp
	{ grep -v '^attempt=' "$file"; printf 'attempt=%d\n' "$n"; } >"$tmp"
	mv "$tmp" "$file"
}

requeue_file() {  # requeue_file FILE  (lock held)
	local file=$1 name=${1##*/}
	rewrite_job "$file" "$Q_PENDING/$name"
	rm -rf "${ARCHCI_HOME:?}/incoming/${name%.job}"
}

# write_job DEST PRIO REPO ARCH PKGBASE VERSION COMMIT PROFILE -> prints the file name
write_job() {
	local dest=$1 prio=$2 repo=$3 arch=$4 pkgbase=$5 version=$6 commit=$7 profile=$8 id
	id="$prio-$(date +%s)-$repo,$pkgbase,$version,$arch"
	archci_valid_id "$id" || archci_die "cannot form a valid job id for $repo/$pkgbase $version $arch"
	cat >"$dest/$id.job.tmp" <<-JOB
		id=$id
		repo=$repo
		arch=$arch
		pkgbase=$pkgbase
		version=$version
		commit=$commit
		profile=$profile
		attempt=0
		created=$(archci_now)
	JOB
	mv "$dest/$id.job.tmp" "$dest/$id.job"
	printf '%s\n' "$id.job"
}

find_job() {  # find_job ID DIR... -> path
	local id=$1 d
	shift
	for d in "$@"; do
		[[ -f $d/$id.job ]] && { printf '%s\n' "$d/$id.job"; return 0; }
	done
	return 1
}
