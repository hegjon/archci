#!/bin/bash
# watchdog-test.sh -- archci_watchdog: a build's output goes through, its exit
# status is kept, and a build that goes silent is killed with its process group.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
export ARCHCI_CONF=/dev/null JOURNAL_STREAM=1
source "$here/../lib/archci-common.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "--- output and exit status pass through"
out=$(archci_watchdog 5 -- bash -c 'echo one; echo two >&2; printf "three"; exit 3') && fail "status 3 expected"
rc=$?; (( rc == 3 )) || fail "status should be 3, got $rc"
[[ $out == $'one\ntwo\nthree' ]] || fail "output mangled: $out"
archci_watchdog 0 -- true || fail "0 must disable the idle limit and still run"

echo "--- a silent build is killed, with its children"
start=$(date +%s)
out=$(archci_watchdog 1 -- bash -c 'echo started; sleep 300.123 & wait') && fail "killed build must not succeed"
rc=$?; (( rc == 124 )) || fail "killed build should return 124, got $rc"
[[ $out == *started* && $out == *"killing the build"* ]] || fail "output: $out"
(( $(date +%s) - start < 60 )) || fail "took too long to kill"
sleep 1
if pgrep -f 'sleep 300.123' >/dev/null; then fail "the build's child process survived"; fi

echo "--- a build that keeps talking is not killed"
# shellcheck disable=SC2016  # the loop runs in the child bash
out=$(archci_watchdog 2 -- bash -c 'for i in 1 2 3; do echo tick $i; sleep 1; done') || fail "chatty build must pass"
[[ $out == $'tick 1\ntick 2\ntick 3' ]] || fail "output: $out"
echo "ALL OK"
