#!/bin/bash
# build-test.sh -- archci-build end to end, with the chroot tools faked: the
# job's PKGBUILD directory is exported from the repository, the clean root
# "made" (mkarchroot faked), the copy made and prepared for real, the
# container runs (arch-nspawn faked: it writes the packages makepkg would),
# and what follows is real: the hash rename, the listings, the builder
# signatures, the records into the journal, the result. Run inside an
# unprivileged user namespace, where the script's root check holds and the
# fixture user is root. What this catches: the code archci-build runs around
# the build, which no other test reaches (0.7.1's journal sender died on a
# missing gem, 0.7.2's contents listing failed on a package with no files).
set -euo pipefail
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for tool in unshare makepkg bsdtar zstd tree gpg rsync git numfmt; do command -v $tool >/dev/null || { echo "skip: $tool missing"; exit 0; }; done
[[ -f /usr/share/devtools/lib/archroot.sh ]] || { echo "skip: devtools missing"; exit 0; }
[[ $(unshare -Ur id -u 2>/dev/null) == 0 ]] || { echo "skip: no unprivileged user namespace here"; exit 0; }

# --- the PKGBUILD repository: one split package, its second half empty ------
pkgs=$tmp/pkgs
mkdir -p "$pkgs/pkgbuilds/duo/.omarchy"
cat >"$pkgs/pkgbuilds/duo/PKGBUILD" <<'PKG'
pkgbase=duo
pkgname=(duo duo-meta)
pkgver=1
pkgrel=1
arch=(x86_64)
package_duo() { :; }
package_duo-meta() { :; }
PKG
echo '{"source": "arch", "nocheck": true}' >"$pkgs/pkgbuilds/duo/.omarchy/package.json"
git -C "$tmp" init -q -b master "$pkgs"
git -C "$pkgs" add -A && git -C "$pkgs" -c user.name=t -c user.email=t@t commit -q -m duo
commit=$(git -C "$pkgs" rev-parse HEAD)

# --- the fakes: what devtools would do to a real chroot ----------------------
mkdir -p "$tmp/bin"
chroot_version=$(sed -n "s/^CHROOT_VERSION='\(.*\)'/\1/p" /usr/share/devtools/lib/archroot.sh)
cat >"$tmp/bin/mkarchroot" <<SH
#!/bin/bash
# mkarchroot -C pacman.conf -M makepkg.conf -c cache ROOT pkgs...
while [[ \$1 == -* ]]; do case \$1 in -C) pc=\$2; shift 2;; -M) mc=\$2; shift 2;; -c) shift 2;; *) shift;; esac; done
root=\$1
mkdir -p "\$root"/etc/{makepkg.conf.d,sudoers.d} "\$root/tmp"
cp "\$pc" "\$root/etc/pacman.conf"; cp "\$mc" "\$root/etc/makepkg.conf"
printf 'root:x:0:0:root:/root:/bin/bash\n' >"\$root/etc/passwd"; printf 'root:x:0:\n' >"\$root/etc/group"; printf 'root:!!:1::::::\n' >"\$root/etc/shadow"
printf '%s\n' "$chroot_version" >"\$root/.arch-chroot"
echo "==> fake mkarchroot: \$root"
SH
cat >"$tmp/bin/arch-nspawn" <<'SH'
#!/bin/bash
# arch-nspawn [-C conf] [-M conf] [-c cache] DIR [nspawn args] [command...]
printf '%s\n' "$*" >>"$TESTTMP/nspawn-args"
while [[ $1 == -* ]]; do case $1 in -C|-M|-c) shift 2;; *) shift;; esac; done
dir=$1; shift
pkgdest='' startdir=''
while [[ ${1:-} == --* ]]; do
	case $1 in --bind=*:/pkgdest) pkgdest=${1#--bind=}; pkgdest=${pkgdest%:/pkgdest};; --bind=*:/startdir) startdir=${1#--bind=}; startdir=${startdir%:/startdir};; esac
	shift
done
case ${1:-} in
	pacman) echo "fake pacman $*"; exit 0 ;;
	/chrootbuild)
		shift
		if [[ " $* " == *" --nobuild "* ]]; then echo "fake deps install: $*"; exit 0; fi
		echo "fake build: $*"
		# what makepkg would leave in /pkgdest: one package with a file, one with none
		( cd "$startdir" && source ./PKGBUILD
		  for n in "${pkgname[@]}"; do
			d=$(mktemp -d); mkdir -p "$d"
			printf 'pkgname = %s\npkgbase = %s\npkgver = %s-%s\npkgdesc = fake\nurl = x\nbuilddate = 1\npackager = t\nsize = 0\narch = x86_64\n' "$n" "$pkgbase" "$pkgver" "$pkgrel" >"$d/.PKGINFO"
			[[ $n == *-meta ]] || { mkdir -p "$d/usr/bin"; echo hi >"$d/usr/bin/$n"; }
			(cd "$d" && bsdtar -cf - .PKGINFO $( [[ -d usr ]] && echo usr ) | zstd -q >"$pkgdest/$n-$pkgver-$pkgrel-x86_64.pkg.tar.zst")
			rm -rf "$d"
		  done )
		echo "==> Finished making: duo 1-1"
		exit 0 ;;
	*) exit 0 ;;
esac
SH
cat >"$tmp/bin/runuser" <<'SH'
#!/bin/bash
while [[ $1 != -- ]]; do shift; done; shift
exec "$@"
SH
# makepkg on the host: only --verifysource and --printsrcinfo are asked of it
# (the build's makepkg runs in the container), and the real one refuses root
cat >"$tmp/bin/makepkg" <<'SH'
#!/bin/bash
case " $* " in
	*" --printsrcinfo "*) source ./PKGBUILD; printf 'pkgbase = %s\n\tpkgver = %s\n\tpkgrel = %s\n\tarch = x86_64\n' "$pkgbase" "$pkgver" "$pkgrel"; for n in "${pkgname[@]}"; do printf '\npkgname = %s\n' "$n"; done ;;
	*" --verifysource "*) echo "fake makepkg: sources verified" ;;
esac
exit 0
SH
printf '#!/bin/bash\nexit 0\n' >"$tmp/bin/systemctl"
printf '#!/bin/bash\nexit 0\n' >"$tmp/bin/nft"
chmod +x "$tmp/bin"/*

# --- the builder key, the worker's directories, the job -------------------
gpgb=$tmp/gpg-builder; mkdir -p "$gpgb"; chmod 700 "$gpgb"
gpg --homedir "$gpgb" --batch --pinentry-mode loopback --passphrase '' --quick-generate-key 'archci-builder <b@t>' ed25519 sign never 2>/dev/null
whome=$tmp/whome; job=$whome/jobs/omarchy-duo-1-1-x86_64-a1
mkdir -p "$job/out"
cat >"$job/job" <<JOB
id=1-1-omarchy,duo,1-1,x86_64
repo=omarchy
arch=x86_64
pkgbase=duo
version=1-1
commit=$commit
profile=extra
attempt=1
worker=testbox-1
created=2026-09-18T00:00:00Z
lane=fast
nocheck=1
JOB
export TESTTMP=$tmp PATH=$tmp/bin:$PATH HOSTNAME=testbox
export ARCHCI_CONF=/dev/null ARCHCI_WORKER_HOME=$whome ARCHCI_CHROOTS=$tmp/chroots ARCHCI_ARCH=x86_64 ARCHCI_BUILD_USER=root
export ARCHCI_BUILDER_GNUPGHOME=$gpgb ARCHCI_BUILDER_KEY=archci-builder ARCHCI_PKGBUILDS_URL=file://$pkgs ARCHCI_PKGBUILDS_BRANCH=master
export ARCHCI_RELEASE_URL='' ARCHCI_KEYSERVERS='' ARCHCI_BUILD_MAX_IDLE_MINUTES=1 ARCHCI_PACKAGER='t <t@t>' ARCHCI_BUILD_ENV=''
journal=0; [[ -S /run/systemd/journal/socket ]] && { export JOURNAL_STREAM=1; journal=1; }

echo "--- archci-build builds a split package end to end (fake chroot tools, real everything else)"
if ! unshare -Ur "$here/../worker/archci-build" "$job/job" "$job/out" 1 >"$tmp/build.log" 2>&1; then
	echo "archci-build exited $?; its log:"; cat "$tmp/build.log"; fail "the build must succeed"
fi
log=$tmp/build.log
[[ $(<"$job/out/result") == success ]] || fail "the result file says success: $(cat "$job/out/result")"
grep -q '^lane         fast (CPU and IO weight 500 among the builds)' "$log" || fail "the lane and its weight are in the header: $(grep -n lane "$log")"
# archci's own records: on stdout without a journal; with one, in the journal
# (readable here or not) and not on stdout
records() {   # the record lines, wherever they went
	if (( journal )); then journalctl -q -o cat --since "-3min" "ARCHCI_JOB=1-1-omarchy,duo,1-1,x86_64" 2>/dev/null || true
	else grep '^==> ' "$log"; fi
}
if (( journal )); then
	! grep -q '^==> PKGBUILD as built' "$log" || fail "with a journal the records go to it, not stdout"
	if [[ -n $(records) ]]; then
		records | grep -q '^==> PKGBUILD as built ([0-9]* bytes)' || fail "the PKGBUILD record in the journal: $(records | head -5)"
		[[ $(journalctl -q -o json --since "-3min" "ARCHCI_JOB=1-1-omarchy,duo,1-1,x86_64" ARCHCI_EVENT=pkgbuild 2>/dev/null | python3 -c 'import sys,json; e=[json.loads(l) for l in sys.stdin]; v=e[-1].get("ARCHCI_PKGBUILD","") if e else ""; v=bytes(v).decode() if isinstance(v,list) else v; print(v.count("\n"))' 2>/dev/null) -ge 5 ]] || fail "the PKGBUILD field holds the file, newlines and all"
	else
		echo "(the journal cannot be read here: the record lines not checked)"
	fi
else
	grep -q '^==> PKGBUILD as built ([0-9]* bytes)' "$log" || fail "the PKGBUILD record's line"
fi
grep -q '^==> Package directory (pkgbuilds/duo at ' "$log" || fail "the package directory listing"
grep -q '^    ├── .omarchy' "$log" || fail "the directory tree lists .omarchy: $(grep -A3 'Package directory' "$log")"
grep -q 'check() skipped: the package says so' "$log" || fail "nocheck from the job is applied"
grep -q '^==> Contents of duo-1-1-x86_64 ([1-9][0-9]* files, ' "$log" || fail "the first package's contents: $(grep 'Contents of' "$log")"
grep -q '^    └── usr' "$log" || fail "its file tree"
grep -q '^==> Contents of duo-meta-1-1-x86_64 (0 files, ' "$log" || fail "the empty package's contents line: $(grep 'Contents of' "$log")"
grep -q '^    (no files)' "$log" || fail "an empty package says (no files) and the build goes on"
(( journal )) || grep -q '^==> archci-build finished with 0 at ' "$log" || fail "the finish line"
! grep -q 'the journal sender is gone' "$log" || fail "the journal sender must stay alive for the PKGBUILD record (a gem the workers lack?): $(grep -n 'sender' "$log")"
# the container's arguments: the lane's weights on the scope, --nocheck to makepkg, deps online then the build offline
args=$tmp/nspawn-args
grep -q -- '--property=CPUWeight=500 --property=IOWeight=500' "$args" || fail "the scope carries the fast lane's weights: $(grep -c property "$args")"
grep -q -- '--slice=archci-online /chrootbuild .*--nobuild' "$args" || fail "the dependencies install online"
grep -q -- '--slice=archci-offline /chrootbuild .*--nocheck' "$args" || fail "the build runs offline with --nocheck: $(grep chrootbuild "$args")"
# the outputs: two packages under their hashed names, each builder-signed
mapfile -t built < <(ls "$job/out"/*.pkg.tar.zst)
(( ${#built[@]} == 2 )) || fail "two packages: $(ls "$job/out")"
for p in "${built[@]}"; do
	[[ $p =~ -x86_64-[0-9a-f]{64}\.pkg\.tar\.zst$ ]] || fail "hashed name: $p"
	[[ -f $p.buildsig ]] || fail "builder signature: $p"
	gpg --homedir "$gpgb" --batch --verify "$p.buildsig" "$p" 2>/dev/null || fail "the signature verifies: $p"
done
[[ ! -d $tmp/chroots/extra-x86_64/archci-1 || -d $tmp/chroots/extra-x86_64/root ]] || fail "the chroot root and the copy"
[[ -f $tmp/chroots/extra-x86_64/archci-1/chrootbuild ]] || fail "the copy carries /chrootbuild"

echo "--- a build that produces nothing fails, and says so"
: >"$job/out/result"; rm -f "$job/out"/*.pkg.tar.zst*
: >"$tmp/no-packages"
cat >"$tmp/bin/arch-nspawn" <<'SH'
#!/bin/bash
while [[ $1 == -* ]]; do case $1 in -C|-M|-c) shift 2;; *) shift;; esac; done
shift; while [[ ${1:-} == --* ]]; do shift; done
[[ ${1:-} == /chrootbuild ]] && echo "fake build, no output"
exit 0
SH
unshare -Ur "$here/../worker/archci-build" "$job/job" "$job/out" 1 >"$tmp/build2.log" 2>&1 && fail "a build without packages must fail"
grep -q 'build reported success but produced no packages' "$tmp/build2.log" || fail "the reason is said: $(tail -3 "$tmp/build2.log")"
[[ $(<"$job/out/result") == failure ]] || fail "the result file says failure"
echo "ALL OK"
