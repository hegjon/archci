#!/bin/bash
# cli-test.sh -- the archci entry point (archci <name> runs archci-<name> of an
# installed role, help, version) and its bash completion.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
source "$here/fixture.sh"
"$scan" >/dev/null
id=$(claim_id worker-1 x86_64)   # a running job for the completion to offer

echo "--- archci <name> runs archci-<name> of an installed role"
archci=$here/../bin/archci
help=$("$archci" help)   # grep -q on a pipe would SIGPIPE the writer under pipefail
grep -q '^  job  *master-side queue operations' <<<"$help" || fail "archci help must list job with its description"
grep -q '^  top  *top-like view of the farm, redrawn from the master' <<<"$help" || fail "archci help must join a wrapped header line"
grep -q '^  shell' <<<"$help" && fail "archci-shell is not a subcommand"
[[ $("$archci" next x86_64) == "$("$next" x86_64)" ]] || fail "archci next must run archci-next"
[[ $("$archci" job retry -a 2>&1) == *'retried from scratch'* ]] || fail "archci job must pass its arguments on"
! "$archci" shell 2>/dev/null || fail "archci shell must be refused"
[[ $("$archci" version) == "archci "?* && $("$archci" --version) == "$("$archci" version)" ]] || fail "archci version must print a version: $("$archci" version)"
! "$archci" nosuch 2>/dev/null || fail "an unknown subcommand must fail"

echo "--- bash completion: subcommands, job subcommands, job ids"
complete_words() {   # complete_words WORD... -> COMPREPLY for the last (possibly empty) word
	# shellcheck disable=SC2034  # COMP_WORDS/COMP_CWORD are what the completion reads
	COMP_WORDS=("$@") COMP_CWORD=$(( $# - 1 )); COMPREPLY=()
	_archci; printf '%s\n' "${COMPREPLY[@]}"
}
source "$here/../config/bash-completion/archci"
PATH=$here/../bin:$PATH
complete_words archci "" | grep -x job >/dev/null || fail "completion must offer the installed subcommands; archci help says: $("$archci" help 2>&1 | head -5)"
complete_words archci "" | grep -x version >/dev/null || fail "completion must offer version"
complete_words archci to | grep -x top >/dev/null || fail "completion must narrow on the prefix"
complete_words archci job "" | grep -x retry >/dev/null || fail "completion must offer archci job's subcommands"
complete_words archci job retry "" | grep -x -- --all >/dev/null || fail "archci job retry must offer --all"
complete_words archci job retry "" | grep -xF "$id" >/dev/null || fail "archci job retry must offer the queue's job ids: $(complete_words archci job retry "")"
complete_words archci top -- | grep -x -- --json >/dev/null || fail "archci top must offer --json"
echo "ALL OK"
