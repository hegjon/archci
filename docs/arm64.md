# Building for arm64 (aarch64)

Arch Linux itself releases only x86_64: PKGBUILDs carried from it say
`arch=(x86_64)`, devtools ships no aarch64 `makepkg.conf`, and the official
mirrors carry no aarch64 binaries. archci therefore treats aarch64 as a port,
the way the [Arch Linux Ports](https://ports.archlinux.page/) project does: it
builds the same package list at the same commits, passes `--ignorearch` to
makepkg, and takes the base system for the chroot from a third-party aarch64
repo. Expect a long tail of packages that need patches (the kernel,
bootloaders, x86 assembly). Those patches live in the PKGBUILD repository:
omarchy-pkgs keeps them in `pkgbuilds/<name>/.omarchy/patches/` and reapplies
them on every sync from Arch, so a fix is a pull request there, and the
farm builds it once merged. Until then the package stays in `queue/failed`.

1. **Master:** `ARCHCI_ARCHES="x86_64 aarch64"` in `/etc/archci/archci.conf`.
   The `any` packages keep being built by x86_64 workers (`ARCHCI_ANY_ARCH`)
   and are pooled for both arches.
2. **A native aarch64 worker.** Digital Ocean has no ARM droplets; Hetzner
   CAX, Oracle Ampere and AWS Graviton do. Install Arch for aarch64 from the
   Ports project (bootstrap tarballs and the pacman.conf `Server` line are on
   its [aarch64 page](https://ports.archlinux.page/aarch64/), ARMv8.2 and up
   only) or [Arch Linux ARM](https://archlinuxarm.org/). Point the host's
   `/etc/pacman.d/mirrorlist` at that repo and trust its signing key with
   `pacman-key`: devtools' pacman.conf includes the host mirrorlist and
   `arch-nspawn` copies the host's pacman trust into the chroot, so the
   chroot needs no pacman config of its own. Then install the worker
   package as on any worker: `ARCHCI_ARCH` defaults to `uname -m`, so
   `archci-worker@N` builds aarch64 there. The chroot's
   `makepkg.conf` is `arch/aarch64/makepkg.conf` from this tree (devtools'
   x86_64 flags with `-march=armv8-a` and `-mbranch-protection=standard`);
   copy it to `/etc/archci/aarch64/makepkg.conf` to change it, and put a
   `/etc/archci/aarch64/extra.conf` there if the chroot should use a
   different pacman config than the host, for example this repo's own
   aarch64 output.
3. Watch `archci-status`: `built` is reported per `<repo>-<arch>`, and
   `archci-job enqueue REPO PKGBASE 0 aarch64` queues one package by hand.

**An emulated worker instead.** An x86_64 machine can build aarch64 through
QEMU user-mode emulation. It is 5 to 20 times slower per core and some test
suites break under it, so it suits a big desktop or a smoke test rather than
a fleet, but it needs no ARM hardware:

```
pacman -U archci-worker-qemu-aarch64-git-*.pkg.tar.zst
systemctl enable --now archci-worker-aarch64@1
```

The package pulls in `qemu-user-static-binfmt` and ships what devtools lacks:
`/etc/binfmt.d/qemu-aarch64-static.conf`, the stock registration with the C
flag added (F lets binaries inside the chroot find the emulator, C lets
setuid ones such as makepkg's `sudo pacman` keep root; the stock registration
lacks C); a devtools `setarch` alias (arch-nspawn runs `setarch aarch64`,
which the host rejects without one); `/etc/archci/aarch64/extra.conf`,
devtools' pacman.conf with `Architecture = aarch64`, the Ports repo as
`Server` (the host's mirrorlist is x86_64) and pacman's download sandbox
off (qemu has no Landlock or seccomp); and the Ports repo key
`9B2C213B21883BB65CE2FB900CF25682E6BA0751` as the pacman keyring
`archci-ports-aarch64`, which the package's install script populates into
the host keyring because the chroot inherits the host's trust. The
`archci-worker-aarch64@N` instance runs next to the machine's own
`archci-worker@N` and is known to the master as `<host>-aarch64-N`. A
machine outside the VPC only needs the master's public address as `master`
in `/etc/hosts`: jobs and journal both travel over ssh. Expect the first
build to spend a while creating `/var/lib/archbuild/extra-aarch64`.
