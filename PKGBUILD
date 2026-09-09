# shellcheck shell=bash disable=SC2164  # makepkg runs this with set -e
# Maintainer: Jonny Heggheim <hegjon@gmail.com>
#
# Split package: archci holds what every role shares (lib/, the config, the
# archci user); archci-master, archci-worker and archci-signer hold one role
# each (its scripts under /usr/lib/archci/<role>/, run by its units, its
# state directories); archci-cli is the `archci <name>` command line the
# master and the signer are operated with (a worker is run by its units
# only). Keys, R2 config and enabling the role's units stay manual (README
# "Install").
#
# Built from a tagged tarball: the version is the tag. This file is the
# source; tools/release-pkgbuild writes the copy the farm builds (pkgver from
# the tag, the tarball's checksum) into the PKGBUILD repository.

pkgbase=archci
pkgname=(archci archci-cli archci-master archci-worker archci-signer
         archci-worker-qemu-aarch64 archci-worker-qemu-riscv64)
pkgver=0.0.0   # set from the tag by tools/release-pkgbuild
pkgrel=1
pkgdesc='Headless build farm for Arch Linux packages: builds a PKGBUILD repository into a signed pacman repository'
arch=(any)
url='https://github.com/hegjon/archci'
license=(MIT)
makedepends=(gnupg devtools)
source=("https://github.com/hegjon/archci/archive/refs/tags/v${pkgver}.tar.gz")
sha256sums=(SKIP)   # filled in by tools/release-pkgbuild
_src="archci-$pkgver"

_libdir=/usr/lib/archci

# _install_role ROLE UNIT... -> the role's scripts under /usr/lib/archci/ROLE/
# (same layout as the source tree, so they find lib/ relative to themselves;
# `archci <name>` and the units run them there, nothing goes to /usr/bin),
# its units, and its tmpfiles entry.
_install_role() {
  local role=$1 f
  shift
  cd "$srcdir/$_src"
  (cd "$role" && find . -type f -exec install -Dm755 '{}' "$pkgdir$_libdir/$role/{}" \;)
  install -d "$pkgdir/usr/lib/systemd/system"
  for f in "$@"; do
    install -m644 "config/systemd/$f" "$pkgdir/usr/lib/systemd/system/$f"
  done
  install -Dm644 "config/systemd/archci-$role.tmpfiles" "$pkgdir/usr/lib/tmpfiles.d/archci-$role.conf"
}

package_archci() {
  pkgdesc='Headless build farm for Arch Linux packages (shared library, config and user)'
  depends=(bash git)
  backup=(etc/archci/archci.conf)

  cd "$srcdir/$_src"
  (cd lib && find . -type f -exec install -Dm644 '{}' "$pkgdir$_libdir/lib/{}" \;)
  # the live config is a stub (only what differs from the defaults goes in),
  # so an upgrade rarely has a .pacnew to offer; the annotated full sample
  # is documentation
  install -Dm644 config/archci.conf "$pkgdir/etc/archci/archci.conf"
  install -Dm644 config/archci.conf.example "$pkgdir/usr/share/doc/archci/archci.conf.example"
  install -Dm644 config/systemd/archci.sysusers "$pkgdir/usr/lib/sysusers.d/archci.conf"
  install -Dm644 README.md "$pkgdir/usr/share/doc/archci/README.md"
  install -Dm644 docs/*.md -t "$pkgdir/usr/share/doc/archci/docs"
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgbase/LICENSE"
}

package_archci-cli() {
  pkgdesc='Headless build farm for Arch Linux packages (the archci command line: operate the master or the signer)'
  depends=(archci bash-completion)

  cd "$srcdir/$_src"
  # the entry point: `archci <name>` runs archci-<name> of whichever role is installed
  install -Dm755 bin/archci "$pkgdir$_libdir/bin/archci"
  printf '%s\n' "$pkgver-$pkgrel" >"$pkgdir$_libdir/VERSION"   # what `archci version` prints
  install -d "$pkgdir/usr/bin"
  ln -s "$_libdir/bin/archci" "$pkgdir/usr/bin/archci"
  install -Dm644 config/bash-completion/archci "$pkgdir/usr/share/bash-completion/completions/archci"
}

package_archci-master() {
  pkgdesc='Headless build farm for Arch Linux packages (master: sync the PKGBUILD repository, hand out jobs, stage results)'
  depends=(archci-cli ruby jq rsync openssh rclone)
  optdepends=('btrfs-progs: btrfs subvolumes for the state directories'
              'libmicrohttpd: receive worker journals with systemd-journal-remote')

  _install_role master archci-scan.service archci-scan.timer \
    archci-housekeeping.service archci-housekeeping.timer archci-stage.service archci-stage.timer \
    archci-signer-status.service archci-signer-status.timer
  cd "$srcdir/$_src"
  install -Dm644 config/systemd/systemd-journal-remote.service.d/archci.conf \
    "$pkgdir/usr/lib/systemd/system/systemd-journal-remote.service.d/archci.conf"
  install -Dm644 config/systemd/systemd-journal-remote.socket.d/archci.conf \
    "$pkgdir/usr/lib/systemd/system/systemd-journal-remote.socket.d/archci.conf"
  install -Dm644 config/systemd/journal-remote.conf "$pkgdir/usr/lib/systemd/journal-remote.conf.d/archci.conf"
  # sshd reads worker keys from /etc/archci/authorized_keys; a hook reloads sshd
  install -Dm644 config/ssh/sshd_config.d/archci.conf "$pkgdir/etc/ssh/sshd_config.d/archci.conf"
  install -Dm644 config/pacman/archci-sshd.hook "$pkgdir/usr/share/libalpm/hooks/archci-sshd.hook"
}

package_archci-worker() {
  pkgdesc='Headless build farm for Arch Linux packages (worker: builds jobs in clean devtools chroots)'
  depends=(archci devtools rsync openssh gnupg)
  optdepends=('btrfs-progs: snapshot-based clean chroots')

  _install_role worker archci-worker@.service archci-build@.service \
    archci-worker-setup.service archci-logging-remote.service
  cd "$srcdir/$_src"
  # the archci journal namespace the units log to, and its upload to the master
  install -Dm644 config/systemd/journald@archci.conf "$pkgdir/usr/lib/systemd/journald@archci.conf.d/archci.conf"
  install -Dm644 config/systemd/systemd-journal-upload.service.d/archci.conf \
    "$pkgdir/usr/lib/systemd/system/systemd-journal-upload.service.d/archci.conf"
  # Chroot makepkg.conf for every arch devtools ships none for: derived from
  # devtools' x86_64 one (and its conf.d) with arch/<arch>/makepkg.conf.sed, so
  # the ports follow devtools' flags. The build fails if a substitution no
  # longer matches. (arch/<arch>/qemu/ belongs to archci-worker-qemu-<arch>.)
  local dt=/usr/share/devtools/makepkg.conf.d sedf a out f
  for sedf in arch/*/makepkg.conf.sed; do
    a=${sedf#arch/}; a=${a%%/*}; out=$pkgdir$_libdir/arch/$a
    install -d "$out/makepkg.conf.d"
    sed -f "$sedf" "$dt/x86_64.conf" >"$out/makepkg.conf"
    for f in "$dt"/x86_64.conf.d/*.conf; do
      sed -f "$sedf" "$f" >"$out/makepkg.conf.d/${f##*/}"
    done
    grep -q "^CARCH=\"$a\"$" "$out/makepkg.conf" || { echo "$sedf did not set CARCH=$a" >&2; return 1; }
    if grep -rE 'x86|cf-protection|leaf-frame-pointer|lib32' "$out" | grep -v '^[^:]*:#'; then
      echo "x86-only flags survived $sedf; update it for this devtools" >&2; return 1
    fi
  done
}

# _package_qemu_arch ARCH -> the files of an archci-worker-qemu-<arch> package:
# archci-worker-<arch>@.service (the worker template with the arch argument),
# the qemu-<arch> binfmt registration with the C flag, the devtools setarch
# alias, the chroot pacman.conf for that port's repository, and the port's key
# as a pacman keyring archci-ports-<arch> when arch/<arch>/qemu/keys/ has one
# (archci-qemu-setup, run by the package's install script, populates it).
_package_qemu_arch() {
  local a=$1
  cd "$srcdir/$_src"
  install -d "$pkgdir/usr/lib/systemd/system"
  sed -e "s/^Description=archci build worker %i\$/Description=archci build worker %i ($a)/" \
      -e "s#^ExecStart=/usr/lib/archci/worker/archci-worker %i\$#ExecStart=/usr/lib/archci/worker/archci-worker %i $a#" \
      -e "1i # A worker instance building $a: natively on a $a machine, under qemu\n# user-mode emulation on another (archci-worker-qemu-$a). Runs alongside\n# archci-worker@ instances of the machine's own arch; known to the master as\n# <host>-$a-N." \
      config/systemd/archci-worker@.service >"$pkgdir/usr/lib/systemd/system/archci-worker-$a@.service"
  grep -q "^ExecStart=/usr/lib/archci/worker/archci-worker %i $a\$" "$pkgdir/usr/lib/systemd/system/archci-worker-$a@.service" ||
    { echo "could not derive archci-worker-$a@.service from the worker template" >&2; return 1; }
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

# Add-ons for an x86_64 worker: worker instances of another arch under qemu
# user-mode emulation, archci-worker-<arch>@N (the unit is named for what it
# builds), next to the machine's own archci-worker@N (see docs/ports.md). A
# native machine of that arch needs none of this: archci-worker@N builds it
# there. Package metadata has to be literal in each function (makepkg reads
# it from the text); the files come from _package_qemu_arch.
package_archci-worker-qemu-aarch64() {
  pkgdesc='Headless build farm for Arch Linux packages (worker add-on: aarch64 instances on x86_64 under qemu user-mode emulation)'
  depends=(archci-worker qemu-user-static qemu-user-static-binfmt)
  install=archci-worker-qemu-aarch64.install
  backup=(etc/binfmt.d/qemu-aarch64-static.conf etc/archci/aarch64/extra.conf)
  _package_qemu_arch aarch64
}

package_archci-worker-qemu-riscv64() {
  pkgdesc='Headless build farm for Arch Linux packages (worker add-on: riscv64 instances on x86_64 under qemu user-mode emulation)'
  depends=(archci-worker qemu-user-static qemu-user-static-binfmt)
  install=archci-worker-qemu-riscv64.install
  backup=(etc/binfmt.d/qemu-riscv64-static.conf etc/archci/riscv64/extra.conf)
  _package_qemu_arch riscv64
}

package_archci-signer() {
  pkgdesc='Headless build farm for Arch Linux packages (signer: verify builder signatures, release-sign, publish)'
  depends=(archci-cli rclone gnupg)
  backup=(etc/archci/release-gnupg/gpg-agent.conf)

  _install_role signer archci-sign.service archci-sign.timer \
    archci-sign-health.service archci-sign-health.timer
  cd "$srcdir/$_src"
  install -Dm600 config/gnupg/release-gpg-agent.conf "$pkgdir/etc/archci/release-gnupg/gpg-agent.conf"
  chmod 700 "$pkgdir/etc/archci/release-gnupg"
}
