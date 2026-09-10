#!/bin/bash
# config-test.sh -- the settings are defined in one place and described in
# another; keep them in step:
#   * every default in lib/archci-common.sh is in config/archci.conf.example
#     with the same value, and the example names no setting the library lacks
#   * the defaults lib/archci.rb carries (the subset ruby needs) match bash's
#   * the heartbeat stat lists are the same in bash and ruby
# A default computed at run time ($(uname -m), $ARCHCI_ARCH) is only checked
# for presence: the example shows a concrete value for it.
set -euo pipefail
export LC_ALL=C   # comm/join/sort must agree on the order of KEY= lines
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
root=$here/..
fail() { echo "FAIL: $*" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# KEY<tab>value lines (a value may hold '='), values without surrounding quotes
sed -nE 's/^: "\$\{(ARCHCI_[A-Z0-9_]+):?=(.*)\}"$/\1\t\2/p' "$root/lib/archci-common.sh" | sort >"$tmp/lib"
sed -nE 's/^#?(ARCHCI_[A-Z0-9_]+)=(.*)$/\1\t\2/p' "$root/config/archci.conf.example" | sed -E 's/\t("(.*)"|'\''(.*)'\'')$/\t\2\3/' | sort >"$tmp/example"
ARCHCI_CONF=/dev/null ruby -e 'require "'"$root"'/lib/archci"; Archci::DEFAULTS.each { |k, v| puts "#{k}\t#{v}" }' | sort >"$tmp/ruby"
(( $(wc -l <"$tmp/lib") > 20 )) || fail "could not read the library's defaults"

echo "--- every setting is in the example, and the example names no other"
only_lib=$(comm -23 <(cut -f1 "$tmp/lib" | sort) <(cut -f1 "$tmp/example" | sort))
only_ex=$(comm -13 <(cut -f1 "$tmp/lib" | sort) <(cut -f1 "$tmp/example" | sort))
[[ -z $only_lib ]] || fail "settings missing from config/archci.conf.example: $only_lib"
[[ -z $only_ex ]] || fail "config/archci.conf.example names settings the library does not have: $only_ex"

echo "--- the example shows the library's defaults"
bad=$(join -t$'\t' -j1 "$tmp/lib" "$tmp/example" | awk -F'\t' '$2 !~ /\$/ && $2 != $3 { print "  " $1 ": library " $2 " / example " $3 }')
[[ -z $bad ]] || fail "defaults differ:"$'\n'"$bad"

echo "--- lib/archci.rb agrees with lib/archci-common.sh"
only_rb=$(comm -13 <(cut -f1 "$tmp/lib" | sort) <(cut -f1 "$tmp/ruby" | sort))
[[ -z $only_rb ]] || fail "archci.rb has defaults the library does not: $only_rb"
bad=$(join -t$'\t' -j1 "$tmp/lib" "$tmp/ruby" | awk -F'\t' '$2 !~ /\$/ && $2 != $3 { print "  " $1 ": bash " $2 " / ruby " $3 }')
[[ -z $bad ]] || fail "defaults differ:"$'\n'"$bad"

echo "--- the heartbeat stat lists"
bash_stats=$(ARCHCI_CONF=/dev/null bash -c 'source "$1"; echo "$ARCHCI_HOST_STATS $ARCHCI_JOB_STATS"' _ "$root/lib/archci-common.sh")
ruby_stats=$(ARCHCI_CONF=/dev/null ruby -e 'require "'"$root"'/lib/archci"; puts (Archci::HOST_STATS + Archci::JOB_STATS).join(" ")')
[[ $bash_stats == "$ruby_stats" ]] || fail "stat lists differ: bash '$bash_stats' / ruby '$ruby_stats'"
echo "ALL OK"
