# Test instance

A live prototype runs on Digital Ocean and publishes what it builds to R2:

- **Repository URL:** `https://pub-082311edbe1f4fcd95c9cfc965318156.r2.dev`
  (the `[archci-test2]` repo lives under `archci-test2/os/<arch>/`, for
  x86_64, aarch64 and riscv64; its build logs under `archci-test2/log/`).
  The repository of the farm's first months, `[hegjon-test]` at
  `https://pub-771dbcd770ba439baaf9c08e090268f8.r2.dev`, is kept as an
  archive and no longer updated.
- **Front end:** <https://repo.jonnyware.com/> (read-only; the queue
  commands are off).
- **Fleet:** a master, build workers, a sourcer, a signer, and the web
  front-end host, all small droplets, plus the desktop building the emulated
  aarch64 and riscv64 arches. It builds the
  `source: arch` packages of
  [hegjon/omarchy-pkgs](https://github.com/hegjon/omarchy-pkgs)
  (`ARCHCI_PKG_SOURCES=arch`), and archci's own release packages from the
  same repository, so the fleet upgrades itself with `pacman -Syu`.
- **Release key:** the throwaway demo key, fingerprint
  `1E29618FAE38DE36160903CD60A80B4278269BB3` (uid `archci release TEST`), with
  no passphrase, so the signer runs unattended.

This is a prototype demo, treat it accordingly:

- The release key is a **throwaway** without a passphrase, so the
  signatures prove the pipeline works, not that the packages are trustworthy.
- The workers are undersized, so large packages (gcc, glibc, …) fail; expect
  gaps.
- It may change, be rebuilt, or disappear without notice.

So try it only on a throwaway machine, a VM or container, never a system you
care about. Fetch and trust the demo key (published in the bucket), then add the
repo:

```
curl -O https://pub-082311edbe1f4fcd95c9cfc965318156.r2.dev/release.pub
pacman-key --add release.pub
pacman-key --lsign-key 1E29618FAE38DE36160903CD60A80B4278269BB3
```

`/etc/pacman.conf`:

```
[archci-test2]
SigLevel = Required DatabaseOptional
Server = https://pub-082311edbe1f4fcd95c9cfc965318156.r2.dev/$repo/os/$arch
```

Then `pacman -Sy` and install as shown in the README under "Using the repo".
The archci packages themselves are there too: `pacman -S archci-worker`
(or `archci-master`, `archci-signer`, `archci-worker-qemu-aarch64`) installs
the latest tagged release, and `pacman -Syu` follows the next ones.
