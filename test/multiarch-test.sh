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
frame=$("$top")
[[ $frame == *"outstanding: 0 update(s), 6 unbuilt"* && $frame == *" aarch64 0/3"* && $frame == *" any 0/1"* ]] || fail "top frame: $frame"
! "$job" claim worker-6 riscv64 2>/dev/null || fail "claim for an arch not in ARCHCI_ARCHES must fail"
# a multilib package (lib32-*) is x86_64's alone, however --ignorearch treats the arch array
mkpkgbuild lib32-zlib 1.3.2-1 x86_64 '{"source": "arch", "arch_repo": "multilib"}'
commit_pkgs lib32
"$scan" >/dev/null
[[ $("$next" aarch64) != *lib32-zlib* ]] || fail "a multilib package must not be offered to aarch64: $("$next" aarch64)"
[[ $("$next" x86_64 | grep -c lib32-zlib) == 1 ]] || fail "but to x86_64: $("$next" x86_64)"
# a package listing aarch64 only (hyprland-guiutils in omarchy-pkgs) is not offered to x86_64, which builds without --ignorearch
mkpkgbuild armonly 1-1 aarch64 '{"source": "local"}'
commit_pkgs armonly
"$scan" >/dev/null
[[ $("$next" x86_64 | grep -c armonly) == 0 ]] || fail "a package not listing x86_64 must not be offered to it: $("$next" x86_64)"
[[ $(ARCHCI_IGNOREARCH=0 "$next" aarch64) == "5 omarchy aarch64 armonly "* ]] || fail "but to aarch64, the only one listing it: $(ARCHCI_IGNOREARCH=0 "$next" aarch64)"
# an AUR (or local) package lists the arches it has binaries for: one listing x86_64 only is not offered to aarch64, --ignorearch or not
mkpkgbuild bun-bin 1-1 x86_64 '{"source": "aur"}'
commit_pkgs bun-bin
"$scan" >/dev/null
[[ $(ARCHCI_PKG_SOURCES=aur "$next" x86_64) == "5 omarchy x86_64 bun-bin "* ]] || fail "an AUR package listing x86_64 is offered to it: $(ARCHCI_PKG_SOURCES=aur "$next" x86_64)"
[[ -z $(ARCHCI_PKG_SOURCES=aur "$next" aarch64) ]] || fail "an AUR package not listing aarch64 must not be offered to it: $(ARCHCI_PKG_SOURCES=aur "$next" aarch64)"
rm -rf "$pkgs/pkgbuilds/lib32-zlib" "$pkgs/pkgbuilds/armonly" "$pkgs/pkgbuilds/bun-bin"; commit_pkgs "no lib32, no armonly, no bun-bin"; "$scan" >/dev/null   # the rest of the test expects the original set
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
frame=$("$top")
[[ $frame == *" x86_64 1/"* && $frame == *" aarch64 1/"* && $frame == *" any 1/"* ]] || fail "top built line: $frame"
echo "ALL OK"
