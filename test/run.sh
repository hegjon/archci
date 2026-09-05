#!/bin/bash
# run.sh -- run every archci test (test/*-test.sh) and report a summary.
# Each test is a standalone script that exits 0 on success. Pass a name
# substring to run only matching tests:  test/run.sh lint
set -uo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
filter=${1:-}
pass=0 fail=0 failed=()

for t in "$here"/*-test.sh; do
	name=$(basename "$t" .sh)
	[[ -n $filter && $name != *"$filter"* ]] && continue
	printf '\n\033[1m### %s\033[0m\n' "$name"
	if "$t"; then
		printf '\033[32mPASS\033[0m %s\n' "$name"; (( ++pass ))
	else
		printf '\033[31mFAIL\033[0m %s (exit %d)\n' "$name" "$?"; (( ++fail )); failed+=("$name")
	fi
done

printf '\n======== %d passed, %d failed ========\n' "$pass" "$fail"
(( fail )) && { printf 'failed: %s\n' "${failed[*]}"; exit 1; }
(( pass )) || { echo "no tests matched '$filter'" >&2; exit 2; }
exit 0
