#!/bin/bash
# multiarch-test.sh -- more than one architecture: workers claim by arch, a
# package uploaded for the wrong arch fails, "any" packages are built once on
# ARCHCI_ANY_ARCH and pooled for every arch, and a newly enabled arch gets
# them again.
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
source "$here/fixture.sh"
"$scan" >/dev/null
# acl is already built for x86_64
id=$(claim_id worker-1 x86_64)
[[ $id == *,acl,* ]] || fail "expected acl first: $id"
upload_ok "$id" acl 1:2.3.2-1
"$job" report "$id" success
[[ -f $ARCHCI_HOME/built/omarchy-x86_64/acl ]] || fail "acl not recorded built for x86_64"

echo "--- multi-arch: workers claim by arch, any packages are pooled for every arch"
export ARCHCI_ARCHES="x86_64 aarch64"   # any packages default to the first: x86_64
mkpkgbuild archlinux-keyring 20260901-1 any
commit_pkgs any
"$scan"
# x86_64: linux, libsigc++ (acl built); any: archlinux-keyring; aarch64: acl, linux, libsigc++
"$top" --json | ruby -rjson -e 'j=JSON.parse(STDIN.read); abort "outstanding #{j["outstanding"]}" unless j["outstanding"] == {"updates"=>0, "backlog"=>6}; abort "tracked #{j["tracked"]}" unless j["tracked"]["omarchy-aarch64"] == 3 && j["tracked"]["omarchy-any"] == 1 && j["any_arch"] == "x86_64"'
! "$job" claim worker-6 riscv64 2>/dev/null || fail "claim for an arch not in ARCHCI_ARCHES must fail"
[[ $("$next" aarch64) == "5 omarchy aarch64 acl "* ]] || fail "aarch64 backlog should start at acl: $("$next" aarch64)"
[[ $(ARCHCI_IGNOREARCH=0 "$next" aarch64) == "" ]] || fail "with ARCHCI_IGNOREARCH=0 only packages listing aarch64 are offered"
out=$("$job" claim arm-1 aarch64)
id=$(sed -n 's/^id=//p' <<<"$out")
[[ $id == 5-*-omarchy,acl,1:2.3.2-1,aarch64 ]] || fail "aarch64 job id: $id"
grep -q '^arch=aarch64$' <<<"$out" || fail "job arch"
[[ $("$next" aarch64) == "5 omarchy aarch64 libsigc++ "* ]] || fail "running aarch64 acl must not be offered again"
[[ $("$next" x86_64) == "5 omarchy x86_64 libsigc++ "* ]] || fail "an aarch64 build must not block x86_64: $("$next" x86_64)"

echo "--- a package uploaded for another arch fails the job"
inc=$ARCHCI_HOME/incoming/$id
echo log >"$inc/build.log"; mkpkg "$inc" acl 1:2.3.2-1 x86_64
"$job" report "$id" success
[[ -f $ARCHCI_HOME/queue/failed/$id.job ]] || fail "an aarch64 job uploading an x86_64 package must fail"
"$job" retry "$id"
id=$(claim_id arm-1 aarch64)
[[ $id == *,acl,*,aarch64 ]] || fail "retry should be claimed first: $id"
upload_ok "$id" acl 1:2.3.2-1 aarch64
"$job" report "$id" success
[[ -f $ARCHCI_HOME/queue/done/$id.job ]] || fail "aarch64 job not done"
[[ $(<"$ARCHCI_HOME/built/omarchy-aarch64/acl") == "1:2.3.2-1 $(pkgcommit acl)" ]] || fail "aarch64 built record"
[[ -f $ARCHCI_HOME/repo/omarchy/os/aarch64/acl-1:2.3.2-1-aarch64.pkg.tar.zst.buildsig ]] || fail "aarch64 package not pooled with its buildsig"
[[ ! -e $ARCHCI_HOME/repo/omarchy/os/x86_64/acl-1:2.3.2-1-aarch64.pkg.tar.zst ]] || fail "aarch64 package must not land in x86_64"
[[ -f $ARCHCI_HOME/logs/omarchy/acl/1:2.3.2-1/aarch64/attempt-1.log ]] || fail "aarch64 log path"

echo "--- an any package: offered to ARCHCI_ANY_ARCH workers only, pooled into every arch"
! "$job" enqueue archlinux-keyring 0 2>/dev/null || fail "an any package must be enqueued with ARCH=any"
"$job" enqueue archlinux-keyring 0 any
! "$job" enqueue acl 0 any 2>/dev/null || fail "an x86_64 package must not be enqueued as any"
! "$job" enqueue acl 0 riscv64 2>/dev/null || fail "enqueue for an arch not enabled must fail"
id=$(claim_id arm-2 aarch64)
[[ $id == *,libsigc++,*,aarch64 ]] || fail "an aarch64 worker must skip the pending any job: $id"
id=$(claim_id worker-7 x86_64)
[[ $id == 0-*-omarchy,archlinux-keyring,20260901-1,any ]] || fail "x86_64 worker should get the any job: $id"
upload_ok "$id" archlinux-keyring 20260901-1 any
"$job" report "$id" success
[[ -f $ARCHCI_HOME/queue/done/$id.job ]] || fail "any job not done"
[[ $(<"$ARCHCI_HOME/built/omarchy-any/archlinux-keyring") == "20260901-1 $(pkgcommit archlinux-keyring) x86_64,aarch64" ]] || fail "any built record: $(<"$ARCHCI_HOME/built/omarchy-any/archlinux-keyring")"
for a in x86_64 aarch64; do
	[[ -f $ARCHCI_HOME/repo/omarchy/os/$a/archlinux-keyring-20260901-1-any.pkg.tar.zst ]] || fail "any package not pooled for $a"
	[[ -f $ARCHCI_HOME/repo/omarchy/os/$a/archlinux-keyring-20260901-1-any.pkg.tar.zst.buildsig ]] || fail "any buildsig not pooled for $a"
done
[[ ! -e $ARCHCI_HOME/incoming/$id ]] || fail "incoming not cleaned"
[[ $("$next" x86_64) != *archlinux-keyring* ]] || fail "built any package must not be outstanding"
# enabling another arch makes every any package outstanding again, so the new arch gets them
[[ $(ARCHCI_ARCHES="x86_64 aarch64 riscv64" "$next" x86_64) == *" any archlinux-keyring "* ]] || fail "an any package must be rebuilt for an arch enabled later: $(ARCHCI_ARCHES="x86_64 aarch64 riscv64" "$next" x86_64)"
"$top" --json | ruby -rjson -e 'j=JSON.parse(STDIN.read); abort "built #{j["built"]}" unless j["built"]["omarchy-any"] == 1 && j["built"]["omarchy-aarch64"] == 1 && j["built"]["omarchy-x86_64"] == 1'
echo "ALL OK"
