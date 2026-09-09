#!/bin/bash
# lint-test.sh -- static checks over every archci script.
#   * bash -n on every bash script and ruby -c on every ruby script (always)
#   * shellcheck on the bash scripts, if shellcheck is installed
# Run directly, or via test/run.sh.
set -uo pipefail
root=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
cd "$root" || exit 1
rc=0
note() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; rc=1; }

# Collect scripts by interpreter from the shebang (executables + known suffixes).
mapfile -t files < <(find bin tools lib master worker signer arch test config/bash-completion -type f 2>/dev/null | sort)
bash_files=(PKGBUILD *.install) ruby_files=()   # makepkg sources these as bash
for f in "${files[@]}"; do
	case $(head -1 "$f") in
		*bash*|*/sh) bash_files+=("$f") ;;
		*ruby*)      ruby_files+=("$f") ;;
		*) [[ $f == *.sh ]] && bash_files+=("$f"); [[ $f == *.rb ]] && ruby_files+=("$f") ;;
	esac
done

note "== bash -n (${#bash_files[@]} scripts) =="
for f in "${bash_files[@]}"; do bash -n "$f" || fail "bash -n $f"; done

note "== ruby -c (${#ruby_files[@]} scripts) =="
for f in "${ruby_files[@]}"; do ruby -c "$f" >/dev/null || fail "ruby -c $f"; done

if command -v shellcheck >/dev/null; then
	note "== shellcheck (${#bash_files[@]} scripts) =="
	# Excluded, structural to this codebase (not defects):
	#   SC1091 sourced files not followed; SC2154 vars set indirectly by
	#   archci_read_job/config eval; SC2034 vars exported via "${!ARCHCI_@}";
	#   SC2059 the say() printf-format helper; SC2029 ssh command expands client-side.
	shellcheck -x -e SC1091 -e SC2154 -e SC2034 -e SC2059 -e SC2029 "${bash_files[@]}" || fail "shellcheck"
else
	note "== shellcheck: not installed, skipping (pacman -S shellcheck) =="
fi

(( rc == 0 )) && note "lint OK"
exit $rc
