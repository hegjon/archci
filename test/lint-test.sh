#!/bin/bash
# lint-test.sh -- static checks over every archci script.
#   * bash -n on every bash script and ruby -c on every ruby script (always)
#   * shellcheck on the bash scripts, if shellcheck is installed
#   * systemd-analyze verify on every unit file, if systemd is installed
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

if command -v systemd-analyze >/dev/null; then
	note "== systemd-analyze verify (units) =="
	# The units as the packages install them: a staging root with every unit
	# under /usr/lib/systemd/system and the role scripts under /usr/lib/archci
	# (mode 755, as the PKGBUILD installs them). verify checks that each
	# Exec= command exists under the root, so the other commands the units
	# run (sh, ssh, systemd-journal-remote) are empty executables there. The
	# system's units ours want (sshd, network-online) are not in the root;
	# with --recursive-errors=no a missing wanted unit is not an error.
	root=$(mktemp -d)
	mapfile -t units < <(find config/systemd \( -name '*.service' -o -name '*.timer' -o -name '*.target' -o -name '*.slice' \) | sort)
	install -d "$root/usr/lib/systemd/system"
	install -m644 "${units[@]}" "$root/usr/lib/systemd/system/"
	for d in master worker signer sourcer remote-logging; do
		(cd "$d" && find . -type f -exec install -Dm755 '{}' "$root/usr/lib/archci/$d/{}" \;)
	done
	mapfile -t cmds < <(sed -n 's/^Exec[A-Za-z]*=[-@+!:]*\([^ ]*\).*/\1/p' "${units[@]}" | sort -u)
	for cmd in "${cmds[@]}"; do
		[[ $cmd == /usr/lib/archci/* || -e $root$cmd ]] || install -Dm755 /dev/null "$root$cmd"
	done
	# verify needs /run/systemd, which a host running systemd has; in a
	# chroot (makepkg's check()) it does not exist and the build user cannot
	# make it, so there the check is skipped (CI and the developers' hosts run it).
	if [[ -d /run/systemd ]]; then
		systemd-analyze verify --root="$root" --man=no --recursive-errors=no "$root"/usr/lib/systemd/system/archci-* || fail "systemd-analyze verify"
	else
		note "(no /run/systemd here: skipped)"
	fi
	rm -rf "$root"
else
	note "== systemd-analyze: not installed, skipping =="
fi

(( rc == 0 )) && note "lint OK"
exit $rc
