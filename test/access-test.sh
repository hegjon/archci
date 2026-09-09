#!/bin/bash
# access-test.sh -- how workers reach the master: archci-authorize writes
# forced-command lines (and revokes them), archci-shell as that forced command
# allows the worker subcommands and a restricted rsync upload into incoming/
# and nothing else.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
source "$here/fixture.sh"
authorize=$master/archci-authorize

echo "--- archci-authorize: forced-command lines in a root-owned file, deduplicated"
akf=$tmp/authorized_keys
ssh-keygen -q -t ed25519 -N '' -C worker-x -f "$tmp/wkey"
ARCHCI_AUTHORIZED_KEYS=$akf "$authorize" "$tmp/wkey.pub"
ARCHCI_AUTHORIZED_KEYS=$akf "$authorize" "$tmp/wkey.pub" 2>&1 | grep -q "already authorized" || fail "re-authorizing must be a no-op"
(( $(wc -l <"$akf") == 1 )) || fail "duplicate key line"
grep -q '^command="[^"]*/master/archci-shell",restrict,port-forwarding,permitopen="127.0.0.1:19532" ssh-ed25519 ' "$akf" || fail "authorized line lacks the forced command or tunnel options: $(<"$akf")"
# a line with stale options for a known key is rewritten, not duplicated
sed -i 's/,port-forwarding,permitopen="127.0.0.1:19532"//' "$akf"
ARCHCI_AUTHORIZED_KEYS=$akf "$authorize" "$tmp/wkey.pub" 2>&1 | grep -q "updated" || fail "stale options must be rewritten"
{ (( $(wc -l <"$akf") == 1 )) && grep -q 'permitopen' "$akf"; } || fail "rewrite left the file wrong: $(<"$akf")"
[[ $(stat -c %a "$akf") == 644 ]] || fail "authorized_keys should be world-readable, root-writable"
! ARCHCI_AUTHORIZED_KEYS=$akf "$authorize" 'not a key' 2>/dev/null || fail "garbage must be rejected"

echo "--- archci-authorize --revoke: by key file, by key, by comment"
ssh-keygen -q -t ed25519 -N '' -C archci-worker@other -f "$tmp/okey" >/dev/null
ARCHCI_AUTHORIZED_KEYS=$akf "$authorize" "$tmp/okey.pub"
(( $(grep -c . "$akf") == 2 )) || fail "two keys expected before revoking"
ARCHCI_AUTHORIZED_KEYS=$akf "$authorize" --revoke archci-worker@other 2>&1 | grep -q "revoked 1 key" || fail "revoke by comment"
grep -q 'archci-worker@other' "$akf" && fail "the revoked key must be gone"
grep -q "$(cut -d' ' -f2 "$tmp/wkey.pub")" "$akf" || fail "the other key must stay"
ARCHCI_AUTHORIZED_KEYS=$akf "$authorize" --revoke "$tmp/wkey.pub" 2>&1 | grep -q "revoked 1 key" || fail "revoke by key file"
[[ ! -s $akf ]] || fail "no key should be left: $(<"$akf")"
! ARCHCI_AUTHORIZED_KEYS=$akf "$authorize" --revoke nobody@nowhere 2>/dev/null || fail "revoking an unknown key must fail"
[[ $(stat -c %a "$akf") == 644 ]] || fail "authorized_keys mode must survive a revoke"
# keys from the old per-user file are carried over once
mkdir -p "$ARCHCI_HOME/.ssh"; echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOldKeyOldKeyOldKeyOldKeyOldKeyOldKeyOldKeyOldKe old" >"$ARCHCI_HOME/.ssh/authorized_keys"
ARCHCI_AUTHORIZED_KEYS=$tmp/ak2 "$authorize" "$tmp/wkey.pub"
grep -q ' old$' "$tmp/ak2" && [[ -f $ARCHCI_HOME/.ssh/authorized_keys.migrated ]] || fail "old per-user keys not migrated"

echo "--- ssh forced command + restricted rsync upload"
"$scan" >/dev/null
cat >"$tmp/fakessh" <<'SH'
#!/bin/bash
shift
SSH_ORIGINAL_COMMAND="$*" exec "$ARCHCI_SHELL"
SH
chmod +x "$tmp/fakessh"
export ARCHCI_SHELL=$master/archci-shell
id=$(sed -n 's/^id=//p' < <("$tmp/fakessh" master claim worker-5 x86_64))
[[ -n $id ]] || fail "claim through archci-shell"
mkdir -p "$tmp/out"; echo hi >"$tmp/out/build.log"; mkpkg "$tmp/out" acl 1:2.3.2-1
rsync -a -e "$tmp/fakessh" "$tmp/out/" "master:$id/" || fail "rsync via rrsync"
[[ -f $ARCHCI_HOME/incoming/$id/build.log ]] || fail "upload did not land in incoming/"
! rsync -a -e "$tmp/fakessh" "$tmp/out/" "master:../escape/" 2>/dev/null || fail "rrsync must refuse paths outside incoming"
! "$tmp/fakessh" master housekeeping 2>/dev/null || fail "shell must refuse non-worker commands"
"$tmp/fakessh" master report "$id" success
[[ -f $ARCHCI_HOME/queue/done/$id.job ]] || fail "report through shell"
echo "ALL OK"
