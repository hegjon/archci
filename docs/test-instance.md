# Test instance

A live prototype runs on Digital Ocean and publishes what it builds to R2:

- **Repository URL:** `https://pub-771dbcd770ba439baaf9c08e090268f8.r2.dev`
  (the `[omarchy]` repo lives under `omarchy/os/x86_64/`).
- **Fleet:** one master, two build workers, and one signer, all small droplets
  (1 vCPU, 1 GB). It builds the `source: arch` packages of
  [hegjon/omarchy-pkgs](https://github.com/hegjon/omarchy-pkgs)
  (`ARCHCI_PKG_SOURCES=arch`).
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
curl -O https://pub-771dbcd770ba439baaf9c08e090268f8.r2.dev/release.pub
pacman-key --add release.pub
pacman-key --lsign-key 1E29618FAE38DE36160903CD60A80B4278269BB3
```

`/etc/pacman.conf`:

```
[omarchy]
SigLevel = Required
Server = https://pub-771dbcd770ba439baaf9c08e090268f8.r2.dev/$repo/os/$arch
```

Then `pacman -Sy` and install as shown in the README under "Using the repo".
