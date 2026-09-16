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
ARCHCI_AUTHORIZED_KEYS=$akf "$authorize" "$tmp/wkey.pub" 2>&1 | grep "already authorized" >/dev/null || fail "re-authorizing must be a no-op"
(( $(wc -l <"$akf") == 1 )) || fail "duplicate key line"
grep -q '^command="[^"]*/master/archci-shell",restrict,port-forwarding,permitopen="127.0.0.1:19533" ssh-ed25519 ' "$akf" || fail "authorized line lacks the forced command or tunnel options: $(<"$akf")"
# a line with stale options for a known key is rewritten, not duplicated
sed -i 's/,port-forwarding,permitopen="127.0.0.1:19533"//' "$akf"
ARCHCI_AUTHORIZED_KEYS=$akf "$authorize" "$tmp/wkey.pub" 2>&1 | grep "updated" >/dev/null || fail "stale options must be rewritten"
{ (( $(wc -l <"$akf") == 1 )) && grep -q 'permitopen' "$akf"; } || fail "rewrite left the file wrong: $(<"$akf")"
[[ $(stat -c %a "$akf") == 644 ]] || fail "authorized_keys should be world-readable, root-writable"
! ARCHCI_AUTHORIZED_KEYS=$akf "$authorize" 'not a key' 2>/dev/null || fail "garbage must be rejected"

echo "--- archci-authorize --sourcer: the sourcer's key runs archci-shell sourcer"
ssh-keygen -q -t ed25519 -N '' -C archci-worker@srcr -f "$tmp/skey"
ARCHCI_AUTHORIZED_KEYS=$akf "$authorize" --sourcer "$tmp/skey.pub"
grep -q '^command="[^"]*/master/archci-shell sourcer",restrict,port-forwarding,permitopen="127.0.0.1:19533" ssh-ed25519 .* archci-worker@srcr$' "$akf" || fail "the sourcer's line must name the sourcer role: $(<"$akf")"
ARCHCI_AUTHORIZED_KEYS=$akf "$authorize" --revoke "$tmp/skey.pub" >/dev/null 2>&1
echo "--- archci-authorize --revoke: by key file, by key, by comment"
ssh-keygen -q -t ed25519 -N '' -C archci-worker@other -f "$tmp/okey" >/dev/null
ARCHCI_AUTHORIZED_KEYS=$akf "$authorize" "$tmp/okey.pub"
(( $(grep -c . "$akf") == 2 )) || fail "two keys expected before revoking"
ARCHCI_AUTHORIZED_KEYS=$akf "$authorize" --revoke archci-worker@other 2>&1 | grep "revoked 1 key" >/dev/null || fail "revoke by comment"
grep -q 'archci-worker@other' "$akf" && fail "the revoked key must be gone"
grep -q "$(cut -d' ' -f2 "$tmp/wkey.pub")" "$akf" || fail "the other key must stay"
ARCHCI_AUTHORIZED_KEYS=$akf "$authorize" --revoke "$tmp/wkey.pub" 2>&1 | grep "revoked 1 key" >/dev/null || fail "revoke by key file"
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
echo "--- the sourcer's role: src claims only, and no build's heartbeat"
cat >"$tmp/fakessh-sourcer" <<'SH'
#!/bin/bash
shift
SSH_ORIGINAL_COMMAND="$*" exec "$ARCHCI_SHELL" sourcer
SH
chmod +x "$tmp/fakessh-sourcer"
! "$tmp/fakessh-sourcer" master claim srcr x86_64 >/dev/null 2>&1 || fail "a sourcer key must not claim a build"
! "$tmp/fakessh-sourcer" master heartbeat "$id" >/dev/null 2>&1 || fail "a sourcer key must not beat for a build"
! "$tmp/fakessh" master claim worker-5 src >/dev/null 2>&1 || fail "a worker key must not claim src jobs"
sid=$(sed -n 's/^id=//p' < <("$tmp/fakessh-sourcer" master claim srcr src))
[[ $sid == *,src ]] || fail "the sourcer key must get a src job: $sid"
"$tmp/fakessh-sourcer" master heartbeat "$sid" worker=srcr || fail "the sourcer key beats for its src job"
"$tmp/fakessh-sourcer" master report "$sid" abandoned srcr || fail "the sourcer key reports its src job"
! rsync -a -e "$tmp/fakessh" "$tmp/out/" "master:../escape/" 2>/dev/null || fail "rrsync must refuse paths outside incoming"
! "$tmp/fakessh" master housekeeping 2>/dev/null || fail "shell must refuse non-worker commands"
"$tmp/fakessh" master report "$id" success "$(owner "$id")"
[[ -f $ARCHCI_HOME/queue/done/$id.job ]] || fail "report through shell"

echo "--- the signer's role: lists and fetches what waits, returns signatures, parks a file, and nothing else"
ssh-keygen -q -t ed25519 -N '' -C archci-signer@sgn -f "$tmp/sgkey"
ARCHCI_AUTHORIZED_KEYS=$akf "$authorize" --signer "$tmp/sgkey.pub"
grep -q '^command="[^"]*/master/archci-shell signer",restrict' "$akf" || fail "--signer must set the signer role: $(cat "$akf")"
cat >"$tmp/fakessh-signer" <<'SH'
#!/bin/bash
shift
SSH_ORIGINAL_COMMAND="$*" exec "$ARCHCI_SHELL" signer
SH
chmod +x "$tmp/fakessh-signer"
if command -v rrsync >/dev/null; then
	mkdir -p "$ARCHCI_HOME/repo/omarchy/os/x86_64"; pooled=$(mkpkg "$ARCHCI_HOME/repo/omarchy/os/x86_64" acl 1:2.3.2-1)
	: >"$pooled.buildsig"; prel=omarchy/os/x86_64/${pooled##*/}
	"$tmp/fakessh-signer" master unsigned | grep -qxF "$prel" || fail "the signer key lists what waits: $("$tmp/fakessh-signer" master unsigned)"
	! "$tmp/fakessh" master unsigned >/dev/null 2>&1 || fail "a worker key must not list what waits"
	mkdir -p "$tmp/sin"; printf '%s\n%s.buildsig\n' "$prel" "$prel" >"$tmp/sfetch"
	rsync -a --files-from="$tmp/sfetch" -e "$tmp/fakessh-signer" "master:." "$tmp/sin/" || fail "the signer key fetches from the pool"
	[[ -f $tmp/sin/$prel && -f $tmp/sin/$prel.buildsig ]] || fail "the fetch brings the file and its buildsig: $(find "$tmp/sin" -type f)"
	mkdir -p "$tmp/sout/omarchy/os/x86_64"; : >"$tmp/sout/$prel.sig"
	rsync -a -e "$tmp/fakessh-signer" "$tmp/sout/" "master:." || fail "the signer key returns signatures"
	[[ -f $ARCHCI_HOME/sigs/$prel.sig ]] || fail "a returned signature lands in sigs/, not the pool: $(find "$ARCHCI_HOME/sigs" "$ARCHCI_HOME/repo" -name '*.sig')"
	[[ ! -e $pooled.sig ]] || fail "the signer cannot write into the pool"
	"$tmp/fakessh-signer" master rejected "$prel" builder signature invalid || fail "the signer key parks a file"
	grep -q "builder signature invalid" "$pooled.rejected" || fail "the mark carries the reason"
	! "$tmp/fakessh-signer" master rejected ../etc/passwd nope >/dev/null 2>&1 || fail "a path outside the pool is refused"
	"$tmp/fakessh-signer" master signed && [[ -e $ARCHCI_HOME/publish.needed ]] || fail "signed flags the publish"
	rm -f "$pooled" "$pooled.buildsig" "$pooled.rejected" "$ARCHCI_HOME/sigs/$prel.sig" "$ARCHCI_HOME/publish.needed"
fi
! "$tmp/fakessh-signer" master claim sgn x86_64 >/dev/null 2>&1 || fail "a signer key must not claim"
! "$tmp/fakessh-signer" master snapshot >/dev/null 2>&1 || fail "a signer key must not read the snapshot"

echo "--- the web role: reads the farm, runs the queue commands, claims and uploads nothing"
ssh-keygen -q -t ed25519 -N '' -C archci-web@site -f "$tmp/webkey"
ARCHCI_AUTHORIZED_KEYS=$akf "$authorize" --web "$tmp/webkey.pub"
grep -q '^command="[^"]*/master/archci-shell web",restrict' "$akf" || fail "--web must set the web role: $(cat "$akf")"
cat >"$tmp/fakessh-web" <<'SH'
#!/bin/bash
shift
SSH_ORIGINAL_COMMAND="$*" exec "$ARCHCI_SHELL" web
SH
chmod +x "$tmp/fakessh-web"
snap=$("$tmp/fakessh-web" master snapshot) || fail "the web key reads the snapshot"
[[ $(jq -r '.queue.done' <<<"$snap") == 1 ]] || fail "the snapshot has the queue counts: $(jq -c .queue <<<"$snap")"
[[ $(jq -r --arg id "$id" '.jobs[] | select(.id == $id) | .state' <<<"$snap") == 'done' ]] || fail "the snapshot lists every job with its state"
log=$("$tmp/fakessh-web" master log "$id") || fail "the web key reads a job's log"
[[ $(jq -r '.state' <<<"$log") == 'done' && $(jq -r '.lines | type' <<<"$log") == array ]] || fail "log ID is JSON with the lines: $log"
ent=$("$tmp/fakessh-web" master entries "$id") || fail "the web key reads a job's log as entries"
[[ $(jq -r '.state' <<<"$ent") == 'done' && $(jq -r '.entries | type' <<<"$ent") == array ]] || fail "entries ID is JSON with the entries: $ent"
! "$tmp/fakessh-web" master summary "$id" >/dev/null 2>&1 || fail "summary is the report's, not the web key's"
one=$("$tmp/fakessh-web" master job "$id") || fail "the web key reads one job"
[[ $(jq -r '.id' <<<"$one") == "$id" ]] || fail "job ID returns that job: $one"
! "$tmp/fakessh-web" master log "9-1-omarchy,nope,1-1,x86_64" >/dev/null 2>&1 || fail "log of an unknown job must fail"
"$tmp/fakessh-web" master enqueue acl 0 x86_64 >/dev/null || fail "the web key enqueues"
[[ -n $(ls "$ARCHCI_HOME"/queue/pending/*acl*x86_64.job 2>/dev/null) ]] || fail "the enqueued job must be pending"
! "$tmp/fakessh-web" master claim web-1 x86_64 >/dev/null 2>&1 || fail "a web key must not claim"
! "$tmp/fakessh-web" master heartbeat "$id" worker=web-1 >/dev/null 2>&1 || fail "a web key must not beat"
! "$tmp/fakessh-web" master report "$id" success web-1 >/dev/null 2>&1 || fail "a web key must not report"
! rsync -a -e "$tmp/fakessh-web" "$tmp/out/" "master:$id/" 2>/dev/null || fail "a web key must not upload"
! "$tmp/fakessh" master snapshot >/dev/null 2>&1 || fail "a worker key must not read the snapshot"
echo "ALL OK"
