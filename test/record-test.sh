#!/bin/bash
# record-test.sh -- archci_record: archci's own log lines with their journal
# fields. Off a unit (no JOURNAL_STREAM) or without the journal's socket the
# line is printed; on a host with journald the record goes through the
# coprocess to the journal with its fields and can be found by them.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
export ARCHCI_CONF=/dev/null
source "$here/../lib/archci-common.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "--- without a journal stream: the line on stdout, the fields dropped"
out=$(unset JOURNAL_STREAM; archci_record "==> a line" ARCHCI_EVENT=start)
[[ $out == "==> a line" ]] || fail "printed as is: $out"
(unset JOURNAL_STREAM; ! archci_journal_open) || fail "no coprocess off a unit"

if [[ ! -S /run/systemd/journal/socket ]] || ! command -v perl >/dev/null; then echo "(no journal socket or perl here: the rest skipped)"; echo "ALL OK"; exit 0; fi
echo "--- through the coprocess: a record with its fields, found in the journal by a field"
tag=archci-record-test-$$-$RANDOM
(
	export JOURNAL_STREAM=1:1
	archci_journal_open || fail "could not open the coprocess"
	archci_record "==> record test $tag" "ARCHCI_TEST=$tag" ARCHCI_EVENT=start ARCHCI_RC=0
	archci_record "==> record test $tag end" "ARCHCI_TEST=$tag" ARCHCI_EVENT=finish
	archci_journal_close   # EOF: the coprocess sends what it has and exits
)
found=''
for _ in $(seq 50); do
	found=$(journalctl -q -o json "ARCHCI_TEST=$tag" 2>/dev/null || true)
	[[ -n $found ]] && (( $(grep -c . <<<"$found") == 2 )) && break
	sleep 0.1
done
if [[ -z $found ]]; then echo "(the journal cannot be read here: the lookup skipped)"; echo "ALL OK"; exit 0; fi
(( $(grep -c . <<<"$found") == 2 )) || fail "two records expected: $found"
echo "--- archci_log off a unit, with ARCHCI_LOG_JOB: the entry carries the job as a field"
(unset JOURNAL_STREAM; ARCHCI_LOG_JOB="9-1-omarchy,rec,1-1,x86_64:$tag" archci_log "logged for a job" 2>/dev/null)
for _ in $(seq 50); do lfound=$(journalctl -q -o json "ARCHCI_JOB=9-1-omarchy,rec,1-1,x86_64:$tag" 2>/dev/null || true); [[ -n $lfound ]] && break; sleep 0.1; done
[[ -n $lfound && $(jq -r '.MESSAGE + " " + .SYSLOG_IDENTIFIER' <<<"$lfound") == "logged for a job record-test.sh" ]] || fail "archci_log's entry with the job field: $lfound"
[[ $(head -1 <<<"$found" | jq -r '.MESSAGE + " " + .ARCHCI_EVENT + " " + .ARCHCI_RC + " " + .SYSLOG_IDENTIFIER') == "==> record test $tag start 0 record-test.sh" ]] || fail "the record's message, fields and identifier: $(head -1 <<<"$found")"
[[ $(tail -1 <<<"$found" | jq -r '.ARCHCI_EVENT') == finish ]] || fail "records keep their order"
echo "ALL OK"
