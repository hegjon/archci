# Maintainer: Jonny Heggheim <hegjon@gmail.com>
#
# Split package: archci-git holds what every role shares (lib/, the config,
# the archci user); archci-master-git, archci-worker-git and archci-signer-git
# hold one role each (its scripts as /usr/bin commands, its units, its state
# directories). Keys, R2 config and enabling the role's units stay manual
# (README "Install"); install.sh is the source-tree installer and is not
# packaged.

pkgbase=archci-git
pkgname=(archci-git archci-master-git archci-worker-git archci-signer-git)
pkgver=r0.g0000000
pkgrel=1
pkgdesc='Headless build farm for Arch Linux packages: builds a PKGBUILD repository into a signed pacman repository'
arch=(any)
url='https://github.com/hegjon/archci'
license=(MIT)
makedepends=(git)
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
# units with the /usr/local paths of the tree's units rewritten, and its
# tmpfiles entry.
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
    sed 's#/usr/local/bin/#/usr/bin/#g' "systemd/$f" >"$pkgdir/usr/lib/systemd/system/$f"
  done
  install -Dm644 "systemd/archci-$role.tmpfiles" "$pkgdir/usr/lib/tmpfiles.d/archci-$role.conf"
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
  install -Dm644 systemd/archci.sysusers "$pkgdir/usr/lib/sysusers.d/archci.conf"
  install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgbase/README.md"
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
  install -Dm644 systemd/systemd-journal-remote.service.d/archci.conf \
    "$pkgdir/usr/lib/systemd/system/systemd-journal-remote.service.d/archci.conf"
  install -Dm644 systemd/journal-remote.conf "$pkgdir/usr/lib/systemd/journal-remote.conf.d/archci.conf"
  # sshd reads worker keys from /etc/archci/authorized_keys (reload sshd after installing)
  install -Dm644 ssh/sshd_config.d/archci.conf "$pkgdir/etc/ssh/sshd_config.d/archci.conf"
}

package_archci-worker-git() {
  pkgdesc='Headless build farm for Arch Linux packages (worker: builds jobs in clean devtools chroots)'
  depends=(archci-git devtools rsync openssh gnupg)
  optdepends=('btrfs-progs: snapshot-based clean chroots')
  provides=(archci-worker)
  conflicts=(archci-worker)

  _install_role worker archci-worker@.service archci-build@.service
  cd "$srcdir/$pkgbase"
  (cd arch && find . -type f -exec install -Dm644 '{}' "$pkgdir$_libdir/arch/{}" \;)
}

package_archci-signer-git() {
  pkgdesc='Headless build farm for Arch Linux packages (signer: verify builder signatures, release-sign, publish)'
  depends=(archci-git rclone gnupg)
  provides=(archci-signer)
  conflicts=(archci-signer)

  _install_role signer archci-sign.service archci-sign.timer \
    archci-sign-health.service archci-sign-health.timer
}
