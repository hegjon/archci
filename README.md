# archci

[![CI](https://github.com/hegjon/archci/actions/workflows/ci.yml/badge.svg)](https://github.com/hegjon/archci/actions/workflows/ci.yml)

A headless build farm for Arch Linux packages. One master watches a git
repository of PKGBUILDs, by default
[omarchy-pkgs](https://github.com/hegjon/omarchy-pkgs), for version changes,
any number of workers pull jobs over ssh and build them in clean
btrfs-snapshotted chroots with devtools, and a separate signer verifies,
signs, and publishes the pacman repository to Cloudflare R2. The master holds
no signing key.

The PKGBUILD repository is the manifest: what gets built is exactly what is
merged there, at the commit the master saw. Packages carried from Arch Linux
itself (`source: arch` in omarchy-pkgs, refreshed by its `bin/sync-arch`),
from the AUR, or written locally all look the same to the farm. The
repository URL is one config line (`ARCHCI_PKGBUILDS_URL`), so moving from
one fork to another, say to `omacom/omarchy-pkgs`, is a config change.


> **Status: prototype.** This runs end to end but is not production-hardened.
> Before relying on it, see the checklist in "Notes and limits" (real release
> key, bigger workers, a custom domain for the repo, and so on).

Everything is plain bash and a few small ruby scripts (the scanner, the
next-package picker, and status, sharing one library), plus `ssh`, `git`, `rsync`,
`btrfs`, `systemd` timers and `journald`. There is no daemon: the queue is a directory of
files, and moving a file between `pending/`, `running/`, `done/` and `failed/`
is the whole state machine.

```mermaid
flowchart LR
  subgraph GH["PKGBUILD repository (github.com/hegjon/omarchy-pkgs)"]
    PK["pkgbuilds/&lt;name&gt;/PKGBUILD + .omarchy/package.json"]
  end
  subgraph MASTER["master (holds no key)"]
    SCAN["archci-scan: pull + index"]
    JOB["archci-job: claim / report (ssh)"]
    REAP["archci-job reap: stale / retry"]
    STAGE["archci-stage: pool to staging"]
  end
  subgraph WORKER["worker x N"]
    WL["archci-worker@N"]
    BUILD["archci-build: makechrootpkg + builder-sign"]
  end
  subgraph SIGNER["signer (holds release key)"]
    SIGN["archci-sign: verify buildsig, release-sign, repo-add"]
  end
  subgraph R2["Cloudflare R2"]
    STG[("staging/ : unsigned pkgs + .buildsig")]
    REL[("release/ : signed pkgs + db")]
  end
  PK -->|git pull| SCAN
  WL -->|ssh claim / report| JOB
  WL --> BUILD
  PK -->|git archive at commit| BUILD
  BUILD -->|rsync pkg + .buildsig| JOB
  JOB --> STAGE --> STG --> SIGN --> REL
  REL -->|"pacman, SigLevel=Required"| CLIENTS["clients"]
```

## How it works

**Scanning.** `archci-scan` (ruby, every 10 min) pulls the PKGBUILD
repository (`ARCHCI_PKGBUILDS_URL`, branch `ARCHCI_PKGBUILDS_BRANCH`) into
`pkgbuilds/` and refreshes the package index. `archci-pkgs` builds that index
from every `pkgbuilds/<name>/` holding a PKGBUILD and `.omarchy/package.json`:
the version the PKGBUILD declares (read the way makepkg does, by sourcing it
at file scope with `CARCH` set), the last commit that touched the directory,
its `arch` array, the devtools profile (`multilib` for `arch_repo: multilib`
or a `lib32-` name, else `extra`), the package's `source`, and whether
`skip_build` is set. The index is cached per clone HEAD, so a claim reads one
file. The backlog is never written down: when a worker asks for work,
`archci next <arch>` walks the index and compares each package's version with
`built/<repo>-<arch>/<name>` (`version commit` of the last successful build;
for an `any` package also the arches it was pooled for, so enabling an arch
later makes those packages outstanding again),
skipping packages that are running, queued, waiting for a retry or given up
on. Updates to packages already in our repo come first, then the never-built
rest, alphabetically. A commit that changes a package directory without
changing its version does not rebuild it, the same rule omarchy-pkgs' own
pipeline follows; it does drop a pending or failed job for the older commit.
`ARCHCI_PKG_SOURCES` restricts the farm to packages with a given `source`,
for example `arch` for those carried from Arch Linux; `ARCHCI_PKG_ALSO`
names packages built regardless, such as archci itself.

**Architectures.** `ARCHCI_ARCHES` on the master lists the arches it builds
(default `x86_64`); each worker sends its own `ARCHCI_ARCH` with every claim
and only gets jobs for it. A package whose PKGBUILD says `arch=(any)` is one
job, given to workers of `ARCHCI_ANY_ARCH` (default: the first arch listed),
and the resulting package is pooled into every arch's directory, because
pacman fetches all packages from the client's own `$repo/os/$arch`. Every
other package is offered to every enabled arch: a port arch builds PKGBUILDs
that only list x86_64 with `--ignorearch` (see [docs/ports.md](docs/ports.md)),
unless `ARCHCI_IGNOREARCH=0` limits it to packages that list the arch.

**Workers.** `archci-worker@N` runs `ssh master claim <host>-N <arch>`. The
master's forced command (`archci-shell`) takes the first file in
`queue/pending/` (manual enqueues and retries) the worker's arch can build,
or else asks `archci next` for the next outstanding package and writes a job
for it. The job goes to `running/` stamped with the worker name and attempt,
and is printed. The worker then:

1. exports `pkgbuilds/<name>/` from the PKGBUILD repository at exactly the
   job's commit (`git archive` out of a bare mirror the worker keeps),
2. starts `archci-build@<repo>-<pkgbase>-<version>-a<attempt>.service`, a
   oneshot template unit, with a blocking `systemctl start`. The build has its
   own unit, cgroup and journal, runs at low CPU and I/O priority (`Nice=15`,
   inherited by everything inside the chroot, so sshd and the worker loop
   stay responsive on a busy build machine), and the unit's `TimeoutStartSec` (12 h, change
   with `systemctl edit archci-build@.service`) is the timeout. A build whose
   output stops for `ARCHCI_BUILD_IDLE_MINUTES` (30) is killed earlier: a hung
   test suite otherwise holds the worker for the whole 12 h,
3. inside that unit, builds with `makechrootpkg -c -l archci-N` in
   `/var/lib/archbuild/<profile>-<arch>`; devtools creates the chroot as a
   btrfs subvolume and each build gets a fresh snapshot of it, refreshed with
   `pacman -Syuu` at most once an hour. The chroot's `makepkg.conf` and
   pacman `<profile>.conf` come from `/etc/archci/<arch>/`, then
   `arch/<arch>/` in the archci tree, then devtools,
4. signs each package with the worker's own builder key (`<pkg>.buildsig`,
   internal provenance, see Signing below),
5. takes the build's journal as `build.log`, and rsyncs it with the packages,
   their builder signatures and makepkg logs to `incoming/<jobid>/` on the
   master (the ssh key is jailed to that directory by `rrsync`),
6. reports `success` or `failure`. The verdict comes from a `result` file
   `archci-build` writes last, not from the unit's exit status, because systemd
   counts a build killed by SIGTERM (an external stop) as a clean exit. A
   `TimeoutStartSec` timeout does fail the unit, but the result file also covers
   the stop/kill case, so the worker relies on it uniformly.

While building, a background loop sends a heartbeat every minute
(`ARCHCI_HEARTBEAT_SECONDS`), carrying the machine's load, memory, chroot
disk use and core count, and the job's own CPU, memory and build-tree size
read from its cgroup; the master keeps them with the job for `archci-top`
and `archci-status`. A job
without a heartbeat for 30 minutes is put back in `pending/` by the reaper, so
a worker can be destroyed at any time. On `systemctl stop` the worker reports
`abandoned`, which requeues without counting an attempt.

**Master.** The master holds no signing key and builds no database. On `report
success` the packages and their builder signatures are pooled into
`repo/<repo>/os/<arch>/` by the arch in the package's file name (debug
packages go to `<repo>-debug`, `-any` packages into every enabled arch; a
package of another arch fails the job) and the built record is written.
`archci-stage` (a timer) then `rclone move`s the pool to the R2 staging area,
so the master keeps only packages not yet staged. Failures keep their log
under `logs/<repo>/<pkgbase>/<version>/<arch>/attempt-N.log` and are retried
after 3 hours, up to 3 attempts. A newer commit of the package drops any
pending or failed job for the older one; if its version is still not the
built one it is simply outstanding again.

**Signer.** Everything from staging on is the signer's job; see Signing below.
It verifies each package's builder signature, adds the client-facing release
signature, runs `repo-add`, publishes packages + `.sig` + database to the R2
release area that clients use, and deletes the package from staging.

Builds use dependencies from the official Arch mirrors, not from our own
output, so packages can be built in any order and workers stay simple. A
package that depends on another package of the same repository (most
`omarchy-*` packages do) needs that repository in the chroot: copy
`/usr/share/devtools/pacman.conf.d/extra.conf` to
`/etc/archci/<arch>/extra.conf` on the workers and add the repository, our
own R2 release area or the one the PKGBUILDs were written for, above
`[core]`.

## Signing

Signing is a two-stage chain, the internet-facing master never holds a key, and
R2 is the hand-off between master and signer. The signer needs no access to the
master at all; it talks only to R2.

```mermaid
flowchart TD
  A["worker: makechrootpkg produces pkg"] --> B["gpg detach-sign -u builder to pkg.buildsig<br/>builder key = internal provenance"]
  B -->|"rsync (rrsync-jailed)"| C["master: pool pkg + .buildsig<br/>(holds no key)"]
  C -->|"archci-stage: rclone move"| D[("R2 staging/")]
  D --> E["signer: rclone pull pkg + .buildsig"]
  E --> F{"verify .buildsig against<br/>trusted builder keyring"}
  F -->|"unknown / invalid / missing"| X["REJECT<br/>delete from staging"]
  F -->|valid| G["gpg detach-sign -u release to pkg.sig<br/>release key = client-facing"]
  G --> H["rclone push pkg + .sig to release/<br/>repo-add to db, delete from staging"]
  H --> I[("R2 release/")]
  I -->|"pacman, SigLevel=Required,<br/>one release key in keyring"| J["client verifies pkg.sig"]
```

- **Builder signature (internal).** Each worker has its own OpenPGP key,
  generated locally on first start (`archci-worker-setup`). Right after a build the worker
  signs every package into `<pkg>.buildsig`. This proves which builder made
  the package and that its bytes were not altered afterwards. It is never
  shown to clients and is excluded from what is published.
- **Release signature (client-facing).** The `signer` role runs on its own
  droplet and holds the passphrase-protected release key. `archci-sign` (a
  timer) lists the R2 staging area, pulls each package with its builder
  signature, verifies the builder signature against a keyring of authorized
  builder keys, makes the detached release `<pkg>.sig`, runs `repo-add`, and
  publishes packages + `.sig` + database to the R2 release area, then deletes
  the package from staging. A package whose builder signature is missing,
  invalid, or from an unknown key is rejected and never released.

The two signatures live in separate files on purpose. pacman verifies the
client-facing `<pkg>.sig` against the one release key in its keyring; the
builder signatures stay in staging and never reach the release area, so clients
never need per-worker keys. The release private key never leaves the signer: it
is generated there with a passphrase and unlocked once per session into
`gpg-agent` (`archci sign --unlock`), so the signing timer runs unattended for
the agent's cache lifetime. The database is left unsigned (pacman's default
`DatabaseOptional`); package authenticity is fully covered by the release
signatures. A compromise of the master cannot get a malicious package released:
it holds no key, cannot forge a builder signature, and the signer refuses
anything that fails that check.

Because the hand-off is R2, the signer needs no access to the master, and the
release area is written only by the key holder. It also means neither host must
store the whole repository: R2 does. Use scoped R2 tokens so the master can
only write `staging/` and the signer can read `staging/` and write the release
prefix, and do not serve `staging/` publicly.

Trust bootstrap: export the release public key on the signer and give it to
clients (`pacman-key --add release.pub && pacman-key --lsign-key <fpr>`), and
register each worker's builder public key on the signer once with
`archci-authorize-builder`. Ephemeral fleets can instead share one builder key
baked into the worker image (see `cloud-init/worker.yaml`), registered once.


## Source layout

```
bin/      archci: the entry point, `archci <name>` runs archci-<name> of an installed role
tools/    release-pkgbuild: writes the fork's release PKGBUILD for a tag from PKGBUILD here (developers)
lib/      archci-common.sh (bash) and archci.rb (ruby): config, job files, paths
master/   archci-scan, archci-pkgs, archci-next, archci-job, archci-stage, archci-shell, archci-authorize, archci-status
worker/   archci-worker, archci-build, archci-worker-setup
signer/   archci-sign, archci-sign-health, archci-authorize-builder
arch/     chroot configs for arches devtools ships none for (aarch64/makepkg.conf.sed, qemu/)
config/   what the packages install outside /usr/lib/archci:
  archci.conf  the stub installed as /etc/archci/archci.conf (only what differs from the defaults)
  archci.conf.example  every setting, annotated, installed under /usr/share/doc/archci
  systemd/  units and timers per role, the worker's journal tunnel and
            namespace, tmpfiles and sysusers, journal-remote drop-ins (master)
  ssh/      sshd_config.d/archci.conf: worker keys from /etc/archci/authorized_keys
  pacman/   the hook that reloads sshd when that drop-in is installed
  gnupg/    the signer's release keyring gpg-agent.conf
```

`PKGBUILD` packages the tree with the same layout under `/usr/lib/archci`,
one package per role (see Install).

## Layout on the master (`/var/lib/archci`)

```
pkgbuilds/                  clone of the PKGBUILD repository (ARCHCI_PKGBUILDS_BRANCH)
pkgbuilds.index             package index over it, keyed by the clone's HEAD (archci-pkgs)
queue/{pending,running,done,failed}/<jobid>.job
built/<repo>-<arch>/<name>  "version commit" of the last good build; for an any
                            package also the arches it was pooled for
                            (one directory per arch, plus <repo>-any)
incoming/<jobid>/           worker uploads (btrfs subvolume, rrsync jail)
repo/<repo>/os/<arch>/      pooled packages awaiting staging (btrfs subvolume)
logs/<repo>/<pkgbase>/<version>/<arch>/attempt-N.log
```

The released repository lives on R2, not on the master. The signer keeps only
the databases locally, in `/var/lib/archci-signer/repo/`.

A job file (the id ends with the arch; `any` for an arch-independent package;
`pkgbase` is the package directory, `commit` the PKGBUILD repository commit
the build is pinned to, `profile` the devtools build profile):

```
id=1-1788594133-omarchy,linux,7.2.3.arch1-2,x86_64
repo=omarchy
arch=x86_64
pkgbase=linux
version=7.2.3.arch1-2
tag=7.2.3.arch1-2
commit=5ad4989865a52c7b0a7b49f4117714e0b2b31d3d
attempt=1
created=2026-09-05T07:40:00Z
worker=build-a-1
claimed=2026-09-05T07:41:12Z
```

## Install

All three roles (master, worker, signer) run on Arch or Omarchy machines and
are installed as pacman packages. `PKGBUILD` is a split package built from
the git repository (`makepkg -s` in a checkout), one package per role on top
of a shared one:

- `archci-git`: `lib/` under `/usr/lib/archci`, the config as
  `/etc/archci/archci.conf`, and the `archci` user (sysusers)
- `archci-master-git`, `archci-worker-git`, `archci-signer-git`: the role's
  scripts under `/usr/lib/archci/<role>/` (run as `archci <name>` or by its
  units), its units in `/usr/lib/systemd/system`,
  its directories (tmpfiles), and its dependencies
- `archci-worker-qemu-aarch64-git`, `archci-worker-qemu-riscv64-git`: add-ons
  for an x86_64 worker: aarch64 or riscv64 worker
  instances under qemu user-mode emulation (see [docs/ports.md](docs/ports.md))

What a package cannot ship as a file happens on first start: a worker's
`archci-worker-setup.service` generates its keys and configures journal
streaming, the master's sshd is reloaded by a pacman hook, the signer's
keyrings are directories the package creates. What remains is per-site:
keys to authorize, R2 credentials, and enabling units, listed per role
below. The signer needs only R2 access; workers need only ssh to the master.

To try a change, build the packages from the checkout and install them:

```
makepkg -s && pacman -U archci-git-*.pkg.tar.zst archci-<role>-git-*.pkg.tar.zst
```

### Master

The master droplet is named `master`, and workers reach it as `archci@master`
(add `<private ip> master` to each worker's `/etc/hosts`; the cloud-init
template does this).

```
pacman -U archci-git-*.pkg.tar.zst archci-master-git-*.pkg.tar.zst
systemctl enable --now archci-scan.timer archci-reaper.timer archci-stage.timer archci-signer-status.timer
systemctl enable --now systemd-journal-remote.socket   # worker journals
```

The package creates the `archci` user and the state directories under
`/var/lib/archci`. Make `repo` and `incoming` there btrfs subvolumes if the
filesystem allows. Then:

1. Create an R2 bucket and an API token that may write the `staging/` prefix,
   and write `/etc/archci/rclone.conf` (mode 600):

   ```
   [r2]
   type = s3
   provider = Cloudflare
   access_key_id = ...
   secret_access_key = ...
   endpoint = https://<account-id>.r2.cloudflarestorage.com
   ```

2. Edit `/etc/archci/archci.conf`: `ARCHCI_R2_STAGING="r2:<bucket>/staging"`,
   `ARCHCI_ARCHES`, and the PKGBUILD repository: `ARCHCI_PKGBUILDS_URL`
   (default `https://github.com/hegjon/omarchy-pkgs.git`; set it to
   `https://github.com/omacom/omarchy-pkgs.git` to follow that fork, on the
   workers too), `ARCHCI_PKGBUILDS_BRANCH` (`master`), `ARCHCI_REPO`
   (`omarchy`, the pacman repository name produced) and optionally
   `ARCHCI_PKG_SOURCES`. The master needs no release credentials; the signer
   publishes the release area.

3. Authorize worker keys: `archci authorize worker_key.pub`. This appends
   `command="/usr/lib/archci/master/archci-shell",restrict <key>` to
   `/etc/archci/authorized_keys`, so a worker key can do nothing but the
   protocol. sshd reads that file for the archci user through
   `/etc/ssh/sshd_config.d/archci.conf` (installed by the master package,
   whose pacman hook reloads sshd). It is root's on
   purpose: the archci user, which the forced command and queue scripts run
   as, cannot authorize keys for itself. The signer needs no key on the master.

Clients read the release area (see Signer):

```
[omarchy]
Server = https://<r2 release domain>/$repo/os/$arch
```

### Worker

```
pacman -U archci-git-*.pkg.tar.zst archci-worker-git-*.pkg.tar.zst
systemctl enable --now archci-worker@1
```

`ARCHCI_MASTER` defaults to `archci@master`, so make sure `master` resolves
to the master's address first. The first start runs
`archci-worker-setup.service`: it generates `/etc/archci/worker_key` and the
builder signing key, makes `/var/lib/archbuild` a btrfs subvolume when the
filesystem allows, configures journal streaming from `ARCHCI_JOURNAL_URL`,
and logs the two public keys to authorize:

```
journalctl -u archci-worker-setup            # the keys and the commands to run
archci authorize '<the ssh key line>'         # on the master
archci authorize-builder builder_key.pub      # on the signer
```

Then:

```
systemctl enable --now archci-worker@2                 # more instances = parallel builds
journalctl --namespace=archci -u archci-worker@1 -f    # the loop: claims, results, uploads
systemctl list-units 'archci-build@*'                  # builds running right now
journalctl --namespace=archci -u 'archci-build@*' -f   # their output
```

`archci-worker@N` builds this machine's own arch (`ARCHCI_ARCH`, default
`uname -m`). `archci-worker-<arch>@N` instances build another arch and run
alongside; the master knows them as `<host>-<arch>-N`.

The worker and build units log to the `archci` journal namespace
(`LogNamespace=archci`), a journald instance of its own with files under
`/var/log/journal/<machine-id>.archci/` and limits in
`journald@archci.conf` (4 GB by default, no rate limit). Plain `journalctl
-u archci-worker@1` shows nothing; add `--namespace=archci`, or
`--namespace='*'` for everything. This is what makes the streaming below
carry archci output only.

The host's `/etc/pacman.d/mirrorlist` is copied into the chroot, so give
workers a fast mirror (`https://geo.mirror.pkgbuild.com/$repo/os/$arch`).

`cloud-init/worker.yaml` is a Digital Ocean user-data template that does all
of this on first boot, so workers are created and destroyed with
`doctl compute droplet create/delete`. The same worker key can be shared by
all droplets; workers are identified by hostname, which on DO is the droplet
name. The master may run `archci-worker@1` too if `master` resolves to itself.

### Signer

On a dedicated droplet (it needs only R2 access, not the VPC):

```
pacman -U archci-git-*.pkg.tar.zst archci-signer-git-*.pkg.tar.zst
```

The package creates the release and builder keyrings under `/etc/archci`,
the release one with a one-day `gpg-agent` cache. Then: write
`/etc/archci/rclone.conf` and set
`ARCHCI_R2_STAGING` (read) and `ARCHCI_R2_RELEASE` (write) in
`/etc/archci/archci.conf`, create the passphrase-protected release key,
register each worker's builder key with `archci-authorize-builder`, export the
release public key for clients, and:

```
archci sign --unlock                      # enter the passphrase once per session
systemctl start archci-sign.timer        # sign new packages every 2 minutes
systemctl start archci-sign-health.timer # warn if signing stalls
journalctl -u archci-sign -f
```

The release key is unlocked into `gpg-agent`, whose cache expires (default one
day, `max-cache-ttl` in the release keyring's `gpg-agent.conf`). When it lapses
signing stops silently and packages pile up in staging, so `archci-sign-health`
(a timer) tests the key with `gpg --pinentry-mode error` and checks the staging
depth, and warns loudly into the journal — `ALERT: release key is LOCKED ...` or
a backlog warning past `ARCHCI_STAGING_WARN`. Re-run `archci sign --unlock` when
you see it. The journal streams to the master, so
`journalctl -D /var/log/journal/remote -t archci-sign-health` surfaces it there.

### Using the repo (client)

On a client, import the release public key and point pacman at the release URL:

```
pacman-key --add release.pub && pacman-key --lsign-key <fingerprint>
```

`/etc/pacman.conf`:

```
[core]
SigLevel = Required DatabaseOptional
Server = https://<r2 release domain>/$repo/os/$arch
```

It then behaves like any pacman repository. Queried from the prototype part way
through building `core` (67 packages so far, abridged; this instance predates
the switch to a PKGBUILD repository and still serves `[core]`):

```
$ pacman -Sl core
core acl 2.4.0-1
core attr 2.6.0-1
core audit 4.2.1-1
core bash 5.3.15-1
core binutils 2.47-4
core btrfs-progs 7.1-1
core cryptsetup 2.8.7-1
core dbus 1.16.2-1
core e2fsprogs 1.47.4-1
core glib2 2.88.3-1
core gnupg 2.4.9-3
core iproute2 7.2.0-1
...
core python-brotli 1.2.0-1

$ pacman -Si core/iproute2
Repository      : core
Name            : iproute2
Version         : 7.2.0-1
Description     : IP Routing Utilities
Architecture    : x86_64
URL             : https://git.kernel.org/pub/scm/network/iproute2/iproute2.git
Licenses        : GPL-2.0-or-later
Provides        : iproute
Depends On      : glibc  libxtables.so=12-64  libcap  libcap.so=2-64  libelf  libbpf  libbpf.so=1-64
Download Size   : 1214.64 KiB
Installed Size  : 3181.61 KiB
Packager        : Unknown Packager
Build Date      : Tue Aug 18 07:37:09 2026
Validated By    : SHA-256 Sum
```

(These 67 packages were built before `ARCHCI_PACKAGER` was set, so they show
`Unknown Packager`; builds now stamp `PACKAGER` from `ARCHCI_PACKAGER`. Either
way the package's authenticity comes from the release signature, which pacman
verifies against the imported key on download, not from that field.)

## Documentation

- [docs/operating.md](docs/operating.md): the day-to-day commands, tests
- [docs/monitoring.md](docs/monitoring.md): worker journals on the master
- [docs/ports.md](docs/ports.md): building for aarch64 and riscv64, native or emulated
- [docs/test-instance.md](docs/test-instance.md): the live test instance

## Notes and limits

- Nothing is queued up front: with an empty `built/`, every package in the
  PKGBUILD repository (minus `skip_build` and anything `ARCHCI_PKG_SOURCES`
  excludes) is outstanding and gets built in name order, as workers ask for
  work.
- Packages are built independently against the official mirrors (plus
  whatever `/etc/archci/<arch>/extra.conf` adds). If a build needs a newer
  dependency than the mirror has, or a sibling from this repository that is
  not published yet, it fails and is retried later.
- The master sources every PKGBUILD at file scope (as the `archci` user, in
  a clean environment) to read its version, the same thing `makepkg
  --printsrcinfo` does. The PKGBUILD repository is trusted input; do not
  point `ARCHCI_PKGBUILDS_URL` at one you would not run.
- Upstream source PGP signatures are verified with the keys each PKGBUILD
  ships in `keys/pgp/<fingerprint>.asc`, as Arch's packaging repositories
  do; `archci-build` imports them for the build user before makechrootpkg
  verifies the sources. A package whose keys are missing fails, which is the
  point: the PKGBUILD repository decides which keys are trusted.
  `ARCHCI_MAKEPKG_ARGS=--skippgpcheck` turns the check off.
- Packages are signed by the `signer` role, never on the master; the database
  is left unsigned (`DatabaseOptional`). See Signing above. A built package
  whose builder signature the signer rejects is not re-attempted automatically,
  since that indicates a misconfigured or untrusted worker; investigate the
  signer log.
- The signer's `repo-add -R` keeps only the current version of each package in
  the release database, and `archci-sign` then deletes the superseded package
  files from the R2 release area.
- Unsigned packages transit the R2 `staging/` prefix. Keep it private (never
  served publicly) and use scoped R2 tokens: the master writes only `staging/`,
  the signer reads `staging/` and writes the release prefix.
- Prototype gaps to close before production: the release key is generated with a
  passphrase but must be a real key you control (not a throwaway); serve the
  release bucket from a custom domain rather than the rate-limited r2.dev URL;
  give workers enough RAM (1 GB is too little for large packages); and decide on
  release-key longevity (see the signing section).
- Worker ssh keys are shared secrets; rotate by running `archci-authorize` with
  a new key and deleting the old line from `/etc/archci/authorized_keys`.

## License

MIT. See [LICENSE](LICENSE).
