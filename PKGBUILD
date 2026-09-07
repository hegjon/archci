# Maintainer: Jonny Heggheim <hegjon@gmail.com>
#
# Packages the archci tree as installed by install.sh, but under /usr/lib/archci
# and /usr/bin with the systemd units in /usr/lib/systemd/system. Role setup
# (users, directories, keys, timers) is a separate step after installing:
#   archci-setup master|worker|signer

pkgname=archci-git
pkgver=r0.g0000000
pkgrel=1
pkgdesc='Headless build farm for Arch Linux packages: builds a PKGBUILD repository into a signed pacman repository'
arch=(any)
url='https://github.com/hegjon/archci'
license=(MIT)
depends=(bash git openssh rsync)
optdepends=(
  'ruby: master role (scanner, package picker, status)'
  'jq: master role (package index)'
  'rclone: master and signer roles (R2 hand-off)'
  'btrfs-progs: master and worker roles (subvolumes, snapshot chroots)'
  'devtools: worker role (makechrootpkg)'
  'gnupg: worker and signer roles (builder and release signatures)'
  'libmicrohttpd: master role (systemd-journal-remote)'
)
provides=(archci)
conflicts=(archci)
backup=(etc/archci/archci.conf)
source=("$pkgname::git+https://github.com/hegjon/archci.git")
sha256sums=(SKIP)

pkgver() {
  cd "$pkgname"
  ( set -o pipefail
    git describe --long --tags --abbrev=7 2>/dev/null \
      | sed 's/^v//;s/\([^-]*-g\)/r\1/;s/-/./g' \
      || printf 'r%s.g%s' "$(git rev-list --count HEAD)" "$(git rev-parse --short=7 HEAD)"
  )
}

package() {
  cd "$pkgname"
  local libdir=/usr/lib/archci d f

  # Same layout as the source tree: every script finds lib/ relative to itself.
  for d in lib master worker signer arch; do
    (cd "$d" && find . -type f -exec install -Dm644 '{}' "$pkgdir$libdir/$d/{}" \;)
  done
  chmod 755 "$pkgdir$libdir"/{master,worker,signer}/*
  install -Dm755 install.sh "$pkgdir$libdir/install.sh"
  install -Dm644 archci.conf.example "$pkgdir$libdir/archci.conf.example"

  install -d "$pkgdir/usr/bin"
  ln -s "$libdir/install.sh" "$pkgdir/usr/bin/archci-setup"
  for f in master/* worker/* signer/*; do
    [[ ${f##*/} == archci-shell ]] && continue   # the ssh forced command, not a user command
    ln -s "$libdir/$f" "$pkgdir/usr/bin/${f##*/}"
  done

  # The tree's units name the /usr/local install; the package's live in /usr/bin.
  install -d "$pkgdir/usr/lib/systemd/system/systemd-journal-remote.service.d" \
    "$pkgdir/usr/lib/systemd/journal-remote.conf.d"
  for f in systemd/*.service systemd/*.timer; do
    sed 's#/usr/local/bin/#/usr/bin/#g' "$f" >"$pkgdir/usr/lib/systemd/system/${f##*/}"
  done
  install -m644 systemd/systemd-journal-remote.service.d/archci.conf \
    "$pkgdir/usr/lib/systemd/system/systemd-journal-remote.service.d/archci.conf"
  install -m644 systemd/journal-remote.conf "$pkgdir/usr/lib/systemd/journal-remote.conf.d/archci.conf"

  install -Dm644 archci.conf.example "$pkgdir/etc/archci/archci.conf"
  install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
