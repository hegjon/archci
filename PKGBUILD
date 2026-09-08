# shellcheck shell=bash disable=SC2164  # makepkg runs this with set -e
# Maintainer: Jonny Heggheim <hegjon@gmail.com>
#
# Split package: archci-git holds what every role shares (lib/, the config,
# the archci user); archci-master-git, archci-worker-git and archci-signer-git
# hold one role each (its scripts as /usr/bin commands, its units, its state
# directories). Keys, R2 config and enabling the role's units stay manual
# (README "Install").

pkgbase=archci-git
pkgname=(archci-git archci-master-git archci-worker-git archci-signer-git archci-worker-qemu-aarch64-git)
pkgver=r0.g0000000
pkgrel=1
pkgdesc='Headless build farm for Arch Linux packages: builds a PKGBUILD repository into a signed pacman repository'
arch=(any)
url='https://github.com/hegjon/archci'
license=(MIT)
makedepends=(git gnupg devtools)
source=("$pkgbase::git+https://github.com/hegjon/archci.git")
sha256sums=(SKIP)

_libdir=/usr/lib/archci

pkgver() {
  cd "$pkgbase"
  ( set -o pipefail
    git describe --long --tags --abbrev=7 2>/dev/null \
      | sed 's/^v//;s/\([^-]*-g\)/r\1/;s/-/./g' \
      || printf 'r%s.g%s' "$(git rev-list --count HEAD)" "$(git rev-parse --short=7 HEAD)"
  )
}

# _install_role ROLE UNIT... -> the role's scripts (same layout as the source
# tree, so they find lib/ relative to themselves) as /usr/bin commands, its
# units, and its tmpfiles entry.
_install_role() {
  local role=$1 f
  shift
  cd "$srcdir/$pkgbase"
  (cd "$role" && find . -type f -exec install -Dm755 '{}' "$pkgdir$_libdir/$role/{}" \;)
  install -d "$pkgdir/usr/bin" "$pkgdir/usr/lib/systemd/system"
  for f in "$role"/*; do
    [[ ${f##*/} == archci-shell ]] && continue   # the ssh forced command, not a user command
    ln -s "$_libdir/$f" "$pkgdir/usr/bin/${f##*/}"
  done
  for f in "$@"; do
    install -m644 "config/systemd/$f" "$pkgdir/usr/lib/systemd/system/$f"
  done
  install -Dm644 "config/systemd/archci-$role.tmpfiles" "$pkgdir/usr/lib/tmpfiles.d/archci-$role.conf"
}

package_archci-git() {
  pkgdesc='Headless build farm for Arch Linux packages (shared library, config and user)'
  depends=(bash git)
  backup=(etc/archci/archci.conf)
  provides=(archci)
  conflicts=(archci)

  cd "$pkgbase"
  (cd lib && find . -type f -exec install -Dm644 '{}' "$pkgdir$_libdir/lib/{}" \;)
  install -Dm644 archci.conf.example "$pkgdir/etc/archci/archci.conf"
  install -Dm644 config/systemd/archci.sysusers "$pkgdir/usr/lib/sysusers.d/archci.conf"
  install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgbase/README.md"
  install -Dm644 docs/*.md -t "$pkgdir/usr/share/doc/$pkgbase/docs"
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgbase/LICENSE"
}

package_archci-master-git() {
  pkgdesc='Headless build farm for Arch Linux packages (master: sync the PKGBUILD repository, hand out jobs, stage results)'
  depends=(archci-git ruby jq rsync openssh rclone)
  optdepends=('btrfs-progs: btrfs subvolumes for the state directories'
              'libmicrohttpd: receive worker journals with systemd-journal-remote')
  provides=(archci-master)
  conflicts=(archci-master)

  _install_role master archci-scan.service archci-scan.timer \
    archci-reaper.service archci-reaper.timer archci-stage.service archci-stage.timer
  cd "$srcdir/$pkgbase"
  install -Dm644 config/systemd/systemd-journal-remote.service.d/archci.conf \
    "$pkgdir/usr/lib/systemd/system/systemd-journal-remote.service.d/archci.conf"
  install -Dm644 config/systemd/systemd-journal-remote.socket.d/archci.conf \
    "$pkgdir/usr/lib/systemd/system/systemd-journal-remote.socket.d/archci.conf"
  install -Dm644 config/systemd/journal-remote.conf "$pkgdir/usr/lib/systemd/journal-remote.conf.d/archci.conf"
  # sshd reads worker keys from /etc/archci/authorized_keys; a hook reloads sshd
  install -Dm644 config/ssh/sshd_config.d/archci.conf "$pkgdir/etc/ssh/sshd_config.d/archci.conf"
  install -Dm644 config/pacman/archci-sshd.hook "$pkgdir/usr/share/libalpm/hooks/archci-sshd.hook"
}

package_archci-worker-git() {
  pkgdesc='Headless build farm for Arch Linux packages (worker: builds jobs in clean devtools chroots)'
  depends=(archci-git devtools rsync openssh gnupg)
  optdepends=('btrfs-progs: snapshot-based clean chroots')
  provides=(archci-worker)
  conflicts=(archci-worker)

  _install_role worker archci-worker@.service archci-build@.service \
    archci-worker-setup.service archci-logging-remote.service
  cd "$srcdir/$pkgbase"
  # the archci journal namespace the units log to, and its upload to the master
  install -Dm644 config/systemd/journald@archci.conf "$pkgdir/usr/lib/systemd/journald@archci.conf.d/archci.conf"
  install -Dm644 config/systemd/systemd-journal-upload.service.d/archci.conf \
    "$pkgdir/usr/lib/systemd/system/systemd-journal-upload.service.d/archci.conf"
  # Chroot makepkg.conf for aarch64, which devtools ships none for: derived
  # from devtools' x86_64 one (and its conf.d) with arch/aarch64/makepkg.conf.sed,
  # so it follows devtools' flags. The build fails if a substitution no longer
  # matches. (arch/aarch64/qemu/ is archci-worker-qemu-aarch64-git's.)
  local dt=/usr/share/devtools/makepkg.conf.d out=$pkgdir$_libdir/arch/aarch64 f
  install -d "$out/makepkg.conf.d"
  sed -f arch/aarch64/makepkg.conf.sed "$dt/x86_64.conf" >"$out/makepkg.conf"
  for f in "$dt"/x86_64.conf.d/*.conf; do
    sed -f arch/aarch64/makepkg.conf.sed "$f" >"$out/makepkg.conf.d/${f##*/}"
  done
  grep -q '^CARCH="aarch64"$' "$out/makepkg.conf" || { echo "makepkg.conf.sed did not set CARCH" >&2; return 1; }
  if grep -rE 'x86|cf-protection|leaf-frame-pointer|lib32' "$out" | grep -v '^[^:]*:#'; then
    echo "x86-only flags survived makepkg.conf.sed; update it for this devtools" >&2; return 1
  fi
}

# Add-on for an x86_64 worker: aarch64 worker instances under qemu user-mode
# emulation, archci-worker-aarch64@N (the unit is named for what it builds),
# next to the machine's own archci-worker@N. Ships what devtools lacks for that: the binfmt registration
# with the C flag, the devtools setarch alias, the chroot pacman.conf pointed
# at the Arch Linux Ports aarch64 repo, and that repo's key as a pacman keyring
# the .install script populates (see docs/arm64.md). A native
# aarch64 machine needs none of this: archci-worker@N builds aarch64 there.
package_archci-worker-qemu-aarch64-git() {
  pkgdesc='Headless build farm for Arch Linux packages (worker add-on: aarch64 instances on x86_64 under qemu user-mode emulation)'
  depends=(archci-worker-git qemu-user-static qemu-user-static-binfmt)
  install=archci-worker-qemu-aarch64.install
  backup=(etc/binfmt.d/qemu-aarch64-static.conf etc/archci/aarch64/extra.conf)
  provides=(archci-worker-qemu-aarch64)
  conflicts=(archci-worker-qemu-aarch64 archci-worker-aarch64)
  replaces=(archci-worker-aarch64-git)

  cd "$srcdir/$pkgbase"
  install -Dm644 config/systemd/archci-worker-aarch64@.service "$pkgdir/usr/lib/systemd/system/archci-worker-aarch64@.service"
  cd arch/aarch64/qemu
  install -Dm644 binfmt.d/qemu-aarch64-static.conf "$pkgdir/etc/binfmt.d/qemu-aarch64-static.conf"
  install -Dm644 setarch-aliases.d/aarch64 "$pkgdir/usr/share/devtools/setarch-aliases.d/aarch64"
  install -Dm644 extra.conf "$pkgdir/etc/archci/aarch64/extra.conf"
  install -d "$pkgdir/usr/share/pacman/keyrings"
  GNUPGHOME=$srcdir/gnupg gpg --dearmor <keys/arch-linux-ports-aarch64.asc \
    >"$pkgdir/usr/share/pacman/keyrings/archci-ports-aarch64.gpg"
  install -Dm644 keys/arch-linux-ports-aarch64-trusted "$pkgdir/usr/share/pacman/keyrings/archci-ports-aarch64-trusted"
}

package_archci-signer-git() {
  pkgdesc='Headless build farm for Arch Linux packages (signer: verify builder signatures, release-sign, publish)'
  depends=(archci-git rclone gnupg)
  backup=(etc/archci/release-gnupg/gpg-agent.conf)
  provides=(archci-signer)
  conflicts=(archci-signer)

  _install_role signer archci-sign.service archci-sign.timer \
    archci-sign-health.service archci-sign-health.timer
  cd "$srcdir/$pkgbase"
  install -Dm600 config/gnupg/release-gpg-agent.conf "$pkgdir/etc/archci/release-gnupg/gpg-agent.conf"
  chmod 700 "$pkgdir/etc/archci/release-gnupg"
}
