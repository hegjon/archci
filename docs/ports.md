# Building for other architectures: aarch64, riscv64, x86_64_v4

Arch Linux itself releases only x86_64: PKGBUILDs carried from it say
`arch=(x86_64)`, devtools ships no `makepkg.conf` for anything else, and the
official mirrors carry no other binaries. archci therefore treats every other
arch as a port, the way the [Arch Linux Ports](https://ports.archlinux.page/)
project does: it builds the same package list at the same commits, passes
`--ignorearch` to makepkg for Arch's own PKGBUILDs (an AUR or local package
is built only where its arch array says), and takes the base system for the
chroot from that port's repository. Expect a long tail of packages that need patches (the
kernel, bootloaders, x86 assembly). Those patches live in the PKGBUILD
repository: omarchy-pkgs keeps them in `pkgbuilds/<name>/.omarchy/patches/`
and reapplies them on every sync from Arch, so a fix is a pull request there,
and the farm builds it once merged. Until then the package stays in
`queue/failed`.

What a port needs in archci is one directory, `arch/<arch>/`: the port's
`makepkg.conf` (and `makepkg.conf.d/`), devtools' x86_64 one with the port's
flags, kept in step with devtools by hand, and under `qemu/` what an x86_64 machine needs to
emulate it (binfmt registration, setarch alias, chroot pacman.conf on the
port's repository with a package cache of its own, since ports rebuild the
`any` packages under the same file names, and its signing key if
`archlinux-keyring` does not already trust it). The PKGBUILD turns that into an `archci-worker-qemu-<arch>`
package with an `archci-worker-<arch>@.service`. aarch64 and riscv64 exist
today; the sections below say where each takes its base system from.

## aarch64

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
   `makepkg.conf` is devtools' x86_64 one with the port's flags
   (`arch/aarch64/makepkg.conf`: `-march=armv8-a` and
   `-mbranch-protection=standard` in place of the x86-only flags), kept in
   step with devtools by hand; copy `/usr/lib/archci/arch/aarch64/makepkg.conf`
   to `/etc/archci/aarch64/makepkg.conf` to change it, and put a
   `/etc/archci/aarch64/extra.conf` there if the chroot should use a
   different pacman config than the host, for example this repo's own
   aarch64 output.
3. Watch `archci top`: `built` is reported per `<repo>-<arch>`, and
   `archci job enqueue REPO PKGBASE 0 aarch64` queues one package by hand.

**An emulated worker instead.** An x86_64 machine can build aarch64 through
QEMU user-mode emulation. It is 5 to 20 times slower per core and some test
suites break under it, so it suits a big desktop or a smoke test rather than
a fleet, but it needs no ARM hardware. The same recipe, with the arch
swapped, applies to every `archci-worker-qemu-<arch>` package:

```
pacman -S archci-worker-qemu-aarch64
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

## riscv64

The base system comes from [Arch Linux RISC-V](https://archriscv.felixc.at/),
the port the Arch Linux Ports project grew out of, which covers most of
`extra` and publishes its patches, so fixes for packages that need them can
often be imported rather than written. Its repository layout is
`repo/<name>` rather than `<name>/os/<arch>`, and its packages are signed with
an Arch Linux developer key that `archlinux-keyring` already trusts, so no
extra key is needed on the worker.

- **Master:** add `riscv64` to `ARCHCI_ARCHES`.
- **Native worker:** a RISC-V board or server running Arch Linux RISC-V, with
  the plain worker package: `archci-worker@N` builds riscv64 there.
- **Emulated worker:** `archci-worker-qemu-riscv64` and
  `systemctl enable --now archci-worker-riscv64@1`, exactly as for aarch64.
  Emulated riscv64 is slower still than emulated aarch64; native hardware
  (a Milk-V Pioneer, or a rented RISC-V server) is where volume belongs.
- **Flags:** `arch/riscv64/makepkg.conf` sets `-march=rv64gc -mabi=lp64d`,
  what Arch Linux RISC-V builds for, and drops the x86-only flags.

## x86_64_v4

Not another machine but a feature level of x86_64: x86-64-v4 is the
baseline plus AVX-512 (and v2's and v3's SSE4, AVX2, BMI, FMA), which Zen 4
and Sapphire Rapids up have. Arch builds its own repositories for
x86-64-v3 the same way (devtools ships `x86_64_v3.conf`), and pacman since
6.1 takes several architectures at once. To archci it is a port like the
others, minus the emulation: the same released commits, built with
`--ignorearch` since no PKGBUILD lists `x86_64_v4`, into their own
`<repo>/os/x86_64_v4/` directory and database, by workers whose CPU has the
level. The `any` packages are pooled into it as into every arch.

- **Master:** add `x86_64_v4` to `ARCHCI_ARCHES`. Packages that list
  `x86_64` (AUR and local ones too) are offered to it, since the level runs
  the same binaries; multilib packages stay x86_64's.
- **Worker:** on an x86_64 machine whose `/proc/cpuinfo` has `avx512f`
  (Zen 4, Sapphire Rapids), the plain worker package and one more instance:

  ```
  systemctl enable --now archci-worker-x86_64_v4@1
  ```

  It runs next to the machine's `archci-worker@N` instances and is known to
  the master as `<host>-x86_64_v4-N`. The chroot is
  `/var/lib/archbuild/extra-x86_64_v4`, from `arch/x86_64_v4/makepkg.conf`
  (devtools' x86_64 one with `CARCH=x86_64_v4` and `-march=x86-64-v4`, plus
  `-C target-cpu=x86-64-v4` for Rust) and `arch/x86_64_v4/extra.conf`
  (devtools' extra.conf with `Architecture = x86_64_v4 x86_64`: the farm's
  own level directory first, Arch's x86_64 mirrors for the rest, spelled
  `os/x86_64` since `$arch` expands to the first architecture). Copy either
  to `/etc/archci/x86_64_v4/` to change it. The setarch alias arch-nspawn
  needs is shipped (`x86_64`), as devtools ships one for `x86_64_v3`.
  check() runs: the build is native, so `ARCHCI_EMULATED_NOCHECK` does not
  apply.
- **Clients:** in `/etc/pacman.conf`, `Architecture = x86_64_v4 x86_64` and
  the farm's repository with `Server = <url>/$repo/os/x86_64_v4`, above the
  Arch repositories. That directory holds the level's builds and the `any`
  packages; what the farm has not built for the level comes from Arch's
  x86_64 mirrors as before. There is no second section for the farm's
  x86_64 builds: the database is named after the repository, so a client
  takes one level of it.
- **Expect** a few packages whose build system fights the flags (assembly
  with its own dispatch, tests that compare against baseline output) and
  the x86_64 load again: every core package once more.
