# shellcheck shell=bash disable=SC2164  # makepkg runs this with set -e
# Maintainer: Jonny Heggheim <hegjon@gmail.com>
#
# archci: what every role shares (lib/, config, user). archci-master, -worker,
# -signer, -sourcer: one role each (scripts under /usr/lib/archci/<role>/, units, state
# dirs, its `archci` command line); archci-remote-logging: a host's archci
# journal streamed to the master (workers, the sourcer). Keys, R2 config,
# enabling units: manual.
# Built from the tag's tarball; tools/release-pkgbuild fills in pkgver and the
# checksum for the copy the farm builds.

pkgbase=archci
pkgname=(archci archci-master archci-worker archci-signer archci-sourcer archci-remote-logging
         archci-worker-qemu-aarch64 archci-worker-qemu-riscv64)
pkgver=0.0.0   # set from the tag by tools/release-pkgbuild
pkgrel=1
pkgdesc='Headless build farm for Arch Linux packages: builds a PKGBUILD repository into a signed pacman repository'
arch=(any)
url='https://github.com/hegjon/archci'
license=(MIT)
makedepends=(gnupg)
checkdepends=(ruby jq git rsync openssh gnupg zstd shellcheck)
source=("https://github.com/hegjon/archci/archive/refs/tags/v${pkgver}.tar.gz")
sha256sums=(SKIP)   # filled in by tools/release-pkgbuild
_src="archci-$pkgver"

_libdir=/usr/lib/archci

# _install_role ROLE UNIT... -> scripts under /usr/lib/archci/ROLE/ (tree
# layout, so they find lib/), the units, the tmpfiles entry
_install_role() {
  local role=$1 f
  shift
  cd "$srcdir/$_src"
  (cd "$role" && find . -type f -exec install -Dm755 '{}' "$pkgdir$_libdir/$role/{}" \;)
  install -d "$pkgdir/usr/lib/systemd/system"
  for f in "$@"; do
    install -m644 "config/systemd/$role/$f" "$pkgdir/usr/lib/systemd/system/$f"
  done
  install -Dm644 "config/systemd/$role/archci-$role.tmpfiles" "$pkgdir/usr/lib/tmpfiles.d/archci-$role.conf"
}

# the test suite: throwaway directories, no network
check() {
  cd "$srcdir/$_src"
  test/run.sh
}

package_archci() {
  pkgdesc='Headless build farm for Arch Linux packages (shared library, config and user)'
  depends=(bash git)
  backup=(etc/archci/archci.conf)

  cd "$srcdir/$_src"
  (cd lib && find . -type f -exec install -Dm644 '{}' "$pkgdir$_libdir/lib/{}" \;)
  printf '%s\n' "$pkgver-$pkgrel" >"$pkgdir$_libdir/VERSION"   # `archci version`, the heartbeats
  # the live config is a stub (rarely a .pacnew); the annotated sample is documentation
  install -Dm644 config/archci.conf "$pkgdir/etc/archci/archci.conf"
  install -Dm644 config/archci.conf.example "$pkgdir/usr/share/doc/archci/archci.conf.example"
  install -Dm644 config/systemd/archci.sysusers "$pkgdir/usr/lib/sysusers.d/archci.conf"
  install -Dm644 README.md "$pkgdir/usr/share/doc/archci/README.md"
  install -Dm644 docs/*.md -t "$pkgdir/usr/share/doc/archci/docs"
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgbase/LICENSE"
}

# bin/archci-ROLE as /usr/bin/archci, with the completion (the worker's has only version)
_install_cli() {
  local role=$1
  cd "$srcdir/$_src"
  install -Dm755 "bin/archci-$role" "$pkgdir$_libdir/bin/archci-$role"
  install -d "$pkgdir/usr/bin"
  ln -s "$_libdir/bin/archci-$role" "$pkgdir/usr/bin/archci"
  [[ $role == worker ]] || install -Dm644 config/bash-completion/archci "$pkgdir/usr/share/bash-completion/completions/archci"
}

package_archci-master() {
  pkgdesc='Headless build farm for Arch Linux packages (master: sync the PKGBUILD repository, hand out jobs, stage results)'
  depends=("archci=$pkgver-$pkgrel" bash-completion ruby jq rsync openssh rclone)
  # the release key is never on the master
  conflicts=(archci-signer)
  optdepends=('btrfs-progs: btrfs subvolumes for the state directories'
              'libmicrohttpd: receive worker journals with systemd-journal-remote')

  _install_role master archci-scan.service archci-scan.timer \
    archci-housekeeping.service archci-housekeeping.timer archci-stage.service archci-stage.timer \
    archci-signer-status.service archci-signer-status.timer
  _install_cli master
  cd "$srcdir/$_src"
  install -Dm644 config/systemd/master/archci-journal-remote.service \
    "$pkgdir/usr/lib/systemd/system/archci-journal-remote.service"
  install -Dm644 config/systemd/master/journal-remote.conf "$pkgdir/usr/lib/systemd/journal-remote.conf.d/archci.conf"
  # worker keys: /etc/archci/authorized_keys; the hook reloads sshd
  install -Dm644 config/ssh/sshd_config.d/60-archci.conf "$pkgdir/etc/ssh/sshd_config.d/60-archci.conf"
  install -Dm644 config/pacman/archci-sshd.hook "$pkgdir/usr/share/libalpm/hooks/archci-sshd.hook"
}

package_archci-worker() {
  pkgdesc='Headless build farm for Arch Linux packages (worker: builds jobs in clean devtools chroots)'
  depends=("archci=$pkgver-$pkgrel" "archci-remote-logging=$pkgver-$pkgrel" devtools rsync openssh gnupg)
  optdepends=('btrfs-progs: snapshot-based clean chroots')

  _install_role worker archci-worker@.service archci-build@.service archci-worker-setup.service
  _install_cli worker
  cd "$srcdir/$_src"
  # chroot makepkg.conf per port arch (arch/<arch>/, kept in step with devtools' x86_64 one by hand)
  local a
  for a in arch/*/; do
    a=${a%/}; a=${a#arch/}
    install -Dm644 "arch/$a/makepkg.conf" "$pkgdir$_libdir/arch/$a/makepkg.conf"
    install -Dm644 arch/"$a"/makepkg.conf.d/*.conf -t "$pkgdir$_libdir/arch/$a/makepkg.conf.d"
  done
}

# _package_qemu_arch ARCH -> archci-worker-ARCH@.service, binfmt, setarch alias,
# the port's pacman.conf and its keyring archci-ports-ARCH from arch/ARCH/qemu/
_package_qemu_arch() {
  local a=$1
  cd "$srcdir/$_src"
  install -Dm644 "config/systemd/worker/archci-worker-$a@.service" "$pkgdir/usr/lib/systemd/system/archci-worker-$a@.service"
  cd "arch/$a/qemu"
  install -Dm644 "binfmt.d/qemu-$a-static.conf" "$pkgdir/etc/binfmt.d/qemu-$a-static.conf"
  install -Dm644 "setarch-aliases.d/$a" "$pkgdir/usr/share/devtools/setarch-aliases.d/$a"
  install -Dm644 extra.conf "$pkgdir/etc/archci/$a/extra.conf"
  if [[ -d keys ]]; then
    install -d "$pkgdir/usr/share/pacman/keyrings"
    cat keys/*.asc | GNUPGHOME=$srcdir/gnupg gpg --dearmor >"$pkgdir/usr/share/pacman/keyrings/archci-ports-$a.gpg"
    install -Dm644 keys/*-trusted "$pkgdir/usr/share/pacman/keyrings/archci-ports-$a-trusted"
  fi
}

# x86_64 worker add-ons: archci-worker-ARCH@N instances under qemu (docs/ports.md).
# Metadata must be literal per function (makepkg reads the text).
package_archci-worker-qemu-aarch64() {
  pkgdesc='Headless build farm for Arch Linux packages (worker add-on: aarch64 instances on x86_64 under qemu user-mode emulation)'
  depends=("archci-worker=$pkgver-$pkgrel" qemu-user-static qemu-user-static-binfmt)
  install=archci-worker-qemu-aarch64.install
  backup=(etc/binfmt.d/qemu-aarch64-static.conf etc/archci/aarch64/extra.conf)
  _package_qemu_arch aarch64
}

package_archci-worker-qemu-riscv64() {
  pkgdesc='Headless build farm for Arch Linux packages (worker add-on: riscv64 instances on x86_64 under qemu user-mode emulation)'
  depends=("archci-worker=$pkgver-$pkgrel" qemu-user-static qemu-user-static-binfmt)
  install=archci-worker-qemu-riscv64.install
  backup=(etc/binfmt.d/qemu-riscv64-static.conf etc/archci/riscv64/extra.conf)
  _package_qemu_arch riscv64
}

package_archci-sourcer() {
  pkgdesc='Headless build farm for Arch Linux packages (sourcer: fetches upstream sources into source packages on R2 for the workers)'
  depends=("archci=$pkgver-$pkgrel" "archci-remote-logging=$pkgver-$pkgrel" git rclone gnupg openssh libarchive debugedit)

  _install_role sourcer archci-sourcer.service archci-sourcer.timer
  _install_cli sourcer
}

package_archci-remote-logging() {
  pkgdesc='Headless build farm for Arch Linux packages (remote logging: the archci journal namespace, streamed to the master through an ssh tunnel)'
  depends=("archci=$pkgver-$pkgrel" openssh)

  _install_role remote-logging archci-logging-setup.service archci-logging-tunnel.service
  cd "$srcdir/$_src"
  install -Dm644 config/systemd/remote-logging/journald@archci.conf "$pkgdir/usr/lib/systemd/journald@archci.conf.d/archci.conf"
  install -Dm644 config/systemd/remote-logging/systemd-journal-upload.service.d/archci.conf \
    "$pkgdir/usr/lib/systemd/system/systemd-journal-upload.service.d/archci.conf"
}

package_archci-signer() {
  pkgdesc='Headless build farm for Arch Linux packages (signer: verify builder signatures, release-sign, publish)'
  depends=("archci=$pkgver-$pkgrel" bash-completion rclone gnupg)
  conflicts=(archci-master)
  backup=(etc/archci/release-gnupg/gpg-agent.conf)

  _install_role signer archci-sign.service archci-sign.timer \
    archci-sign-health.service archci-sign-health.timer
  _install_cli signer
  cd "$srcdir/$_src"
  install -Dm600 config/gnupg/release-gpg-agent.conf "$pkgdir/etc/archci/release-gnupg/gpg-agent.conf"
  chmod 700 "$pkgdir/etc/archci/release-gnupg"
}
