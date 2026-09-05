# archci

A headless build farm for Arch Linux. One master watches
[archlinux/packaging/state](https://gitlab.archlinux.org/archlinux/packaging/state)
for released package versions, any number of workers pull jobs over ssh and
build them in clean btrfs-snapshotted chroots with devtools, and the master
publishes a pacman repository plus build logs to Cloudflare R2.

Everything is plain bash, two small ruby scripts, ssh, git, rsync, btrfs,
systemd timers and journald. There is no daemon: the queue is a directory of
files, and moving a file between `pending/`, `running/`, `done/` and `failed/`
is the whole state machine.

```
 gitlab.archlinux.org                         Cloudflare R2
   packaging/state ──git pull──┐        ┌── staging/ ──┐   release/ (clients)
   packaging/packages/*        │        │ unsigned pkgs│      ▲ signed pkgs + db
        │                      ▼        ▼ + .buildsig   │      │
        │              ┌──────────── master ───────────┴──┐   │
        │              │ archci-scan  (timer)  state → queue│   │
        │              │ archci-job   (ssh)    claim/report │   │
        │              │ archci-job reap(timer) stale/retry │   │
        │              │ archci-stage (timer)  pool → staging   │
        │              └───────▲───────────────────────────────┘
        │        ssh "claim"/"report", rsync (rrsync-jailed)
        │                      │              ┌──── signer ─────┴──────┐
        ▼              ┌───────┴─ worker ──┐  │ archci-sign (timer):   │
   git fetch <commit>  │ archci-worker@N   │  │  staging → verify      │
                       │ archci-build      │  │  buildsig → release-   │
                       │ makechrootpkg     │  │  sign → repo-add →     │
                       │ + builder-sign    │  │  release/  (release key)│
                       └───────────────────┘  └────────────────────────┘
```

## How it works

**Scanning.** `archci-scan` (ruby, every 10 min) only pulls the state repo.
Each file `<repo>-<arch>/<pkgbase>` there holds `pkgbase version tag commit`.
The backlog is never written down: when a worker asks for work, `archci-next`
walks the state files and compares each with `built/<repo>-<arch>/<pkgbase>`
(`version commit` of the last successful build), skipping packages that are
running, queued, waiting for a retry or given up on. Updates to packages
already in our repo come first, then the never-built rest, alphabetically.
That walk is about 8,200 small files for core plus extra and takes well
under a second, once per claim.

**Workers.** `archci-worker@N` runs `ssh master claim <host>-N`. The master's
forced command (`archci-shell`) takes the first file in `queue/pending/`
(manual enqueues and retries), or else asks `archci-next` for the next
outstanding package and writes a job for it. The job goes to `running/`
stamped with the worker name and attempt, and is printed. The worker then:

1. fetches the packaging repo at exactly the released commit
   (`archci-build` maps pkgbase to the GitLab path the same way devtools does),
2. starts `archci-build@<repo>-<pkgbase>-<version>-a<attempt>.service`, a
   oneshot template unit, with a blocking `systemctl start`. The build has its
   own unit, cgroup and journal, and the unit's `TimeoutStartSec` (12 h, change
   with `systemctl edit archci-build@.service`) is the timeout,
3. inside that unit, builds with `makechrootpkg -c -l archci-N` in
   `/var/lib/archbuild/<profile>-<arch>`; devtools creates the chroot as a
   btrfs subvolume and each build gets a fresh snapshot of it, refreshed with
   `pacman -Syuu` at most once an hour,
4. signs each package with the worker's own builder key (`<pkg>.buildsig`,
   internal provenance, see Signing below),
5. takes the build's journal as `build.log`, and rsyncs it with the packages,
   their builder signatures and makepkg logs to `incoming/<jobid>/` on the
   master (the ssh key is jailed to that directory by `rrsync`),
6. reports `success` or `failure`. The verdict comes from a `result` file
   `archci-build` writes last, not from the unit's exit status, because
   systemd counts SIGTERM (a timeout, a stop) as a clean exit.

While building, a background loop sends a heartbeat every 5 minutes. A job
without a heartbeat for 30 minutes is put back in `pending/` by the reaper, so
a worker can be destroyed at any time. On `systemctl stop` the worker reports
`abandoned`, which requeues without counting an attempt.

**Master.** The master holds no signing key and builds no database. On `report
success` the packages and their builder signatures are pooled into
`repo/<repo>/os/<arch>/` (debug packages go to `<repo>-debug`) and the built
record is written. `archci-stage` (a timer) then `rclone move`s the pool to the
R2 staging area, so the master keeps only packages not yet staged. Failures
keep their log under `logs/<repo>/<pkgbase>/<version>/attempt-N.log` and are
retried after 3 hours, up to 3 attempts. A newer upstream release drops any
pending or failed job for the older commit; the new commit is simply
outstanding again.

**Signer.** Everything from staging on is the signer's job; see Signing below.
It verifies each package's builder signature, adds the client-facing release
signature, runs `repo-add`, publishes packages + `.sig` + database to the R2
release area that clients use, and deletes the package from staging.

Builds use dependencies from the official Arch mirrors, not from our own
output, so packages can be built in any order and workers stay simple. Point
the chroot at our R2 repo instead by adding it to a copy of
`/usr/share/devtools/pacman.conf.d/extra.conf` if you want a self-hosting
rebuild.

## Signing

Signing is a two-stage chain, the internet-facing master never holds a key, and
R2 is the hand-off between master and signer. The signer needs no access to the
master at all; it talks only to R2.

```
 WORKER (holds builder key)                         builder key = internal provenance
 ─────────────────────────
   git fetch <released commit>  →  makechrootpkg (clean btrfs chroot)
        │                                       ──►  foo-1.2-1.pkg.tar.zst
   gpg --detach-sign -u builder                 ──►  foo-1.2-1.pkg.tar.zst.buildsig
        │
   rsync pkg + .buildsig  ──►  master:incoming/<job>/   (ssh key, rrsync-jailed)
        │
════════╪═══════════════════════ VPC (ssh) ═══════════════════════════════════
        ▼
 MASTER (holds NO key)
 ────────────────────
   pool  →  archci-stage:  rclone move  pkg + .buildsig  ──►  R2 staging/
        │
════════╪══════════════════════ Cloudflare R2 ════════════════════════════════
        ▼
 SIGNER (holds release key + trusted builder keyring)     release key = client-facing
 ──────────────────────────────────────────────────
   rclone pull  staging/pkg + .buildsig
        │
   gpg --verify  .buildsig  against trusted builder keyring
        ├─ unknown / invalid / missing  ──►  REJECT (logged, deleted from staging)
        ▼ valid
   gpg --detach-sign -u release   (passphrase via gpg-agent, 1× unlock)
        │                          ──►  foo-1.2-1.pkg.tar.zst.sig
        ▼
   rclone push  pkg + .sig  ──►  R2 release/ ;  repo-add  ──►  release/<repo>.db
   rclone delete  staging/pkg + .buildsig        (.buildsig never leaves staging)
        │
════════╪══════════════════════ Cloudflare R2 ════════════════════════════════
        ▼
 CLIENT
 ──────
   pacman  fetches from R2 release/ and verifies foo….pkg.tar.zst.sig
           against the ONE release key in its keyring  (SigLevel = Required).
```

- **Builder signature (internal).** Each worker has its own OpenPGP key,
  generated locally by `install.sh worker`. Right after a build the worker
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
`gpg-agent` (`archci-sign --unlock`), so the signing timer runs unattended for
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
lib/      archci-common.sh (bash) and archci.rb (ruby): config, job files, paths
master/   archci-scan, archci-next, archci-job, archci-stage, archci-shell, archci-authorize, archci-status
worker/   archci-worker, archci-build
signer/   archci-sign, archci-authorize-builder
systemd/  scan, reaper and stage timers (master); archci-worker@.service and
          archci-build@.service (worker); archci-sign timer (signer);
          journal-remote drop-ins for the master
```

`install.sh` copies `lib/` plus the role's directory to `/usr/local/lib/archci`
with the same layout and symlinks the role's scripts into `/usr/local/bin`.

## Layout on the master (`/var/lib/archci`)

```
state/                      clone of packaging/state
queue/{pending,running,done,failed}/<jobid>.job
built/<repo>-<arch>/<pkgbase>     "version commit" of the last good build
incoming/<jobid>/           worker uploads (btrfs subvolume, rrsync jail)
repo/<repo>/os/<arch>/      pooled packages awaiting staging (btrfs subvolume)
logs/<repo>/<pkgbase>/<version>/attempt-N.log
```

The released repository lives on R2, not on the master. The signer keeps only
the databases locally, in `/var/lib/archci-signer/repo/`.

A job file:

```
id=1-1788594133-core,linux,7.2.3.arch1-2
repo=core
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

Both roles are Arch or Omarchy machines. Copy or clone this directory there.

### Master

The master droplet is named `master`, and workers reach it as `archci@master`
(add `<private ip> master` to each worker's `/etc/hosts`; the cloud-init
template does this).

```
./install.sh master
```

This installs `lib/` and `master/` to `/usr/local/lib/archci` (symlinked into
`/usr/local/bin`), creates the `archci` user and directories (as btrfs
subvolumes when the filesystem allows), and enables the scan, reaper and stage
timers. Then:

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

2. Edit `/etc/archci/archci.conf`: `ARCHCI_R2_STAGING="r2:<bucket>/staging"`
   and `ARCHCI_REPOS`. The master needs no release credentials; the signer
   publishes the release area.

3. Authorize worker keys: `archci-authorize worker_key.pub`. This appends
   `command="/usr/local/lib/archci/master/archci-shell",restrict <key>` to the archci
   user's `authorized_keys`, so a worker key can do nothing but the protocol.
   The signer needs no key on the master.

Clients read the release area (see Signer):

```
[core]
Server = https://<r2 release domain>/$repo/os/$arch
```

### Worker

```
./install.sh worker
```

Installs devtools, creates the unprivileged `archci` build user, makes
`/var/lib/archbuild` a btrfs subvolume, generates `/etc/archci/worker_key` and
prints the public key to authorize on the master. `ARCHCI_MASTER` defaults
to `archci@master`; make sure `master` resolves to the master's private VPC
address, then:

```
systemctl start archci-worker@1        # one chroot copy per instance
systemctl enable --now archci-worker@2 # more instances = parallel builds
journalctl -u archci-worker@1 -f       # the loop: claims, results, uploads
systemctl list-units 'archci-build@*'  # builds running right now
journalctl -u 'archci-build@*' -f      # their output
```

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
./install.sh signer
```

This installs `rclone` and `gnupg`, and creates the release and builder
keyrings under `/etc/archci` with a one-day `gpg-agent` cache. Then, following
the printed steps: write `/etc/archci/rclone.conf` and set
`ARCHCI_R2_STAGING` (read) and `ARCHCI_R2_RELEASE` (write) in
`/etc/archci/archci.conf`, create the passphrase-protected release key,
register each worker's builder key with `archci-authorize-builder`, export the
release public key for clients, and:

```
archci-sign --unlock              # enter the passphrase once per session
systemctl start archci-sign.timer # sign new packages every 2 minutes
journalctl -u archci-sign -f
```

## Monitoring workers from the master

Workers stream their journal to the master with `systemd-journal-upload`
(configured by `install.sh worker` from `ARCHCI_JOURNAL_URL`, default
`http://master:19532`). The master receives it with `systemd-journal-remote`
over plain HTTP on the VPC and keeps one file per worker under
`/var/log/journal/remote/`, capped by `journal-remote.conf` (2 GB, 200 files).
Same direction as the job protocol: workers only need the master's name, and
the last lines of a worker that died are already on the master.

```
journalctl -D /var/log/journal/remote -f                     all workers, live
journalctl -D /var/log/journal/remote -u 'archci-worker@*'   the worker loops only
journalctl -D /var/log/journal/remote -u 'archci-build@*'    every build's output
journalctl -D /var/log/journal/remote -u archci-build@core-linux-7.2.3.arch1-2-a1
journalctl -D /var/log/journal/remote _HOSTNAME=build-a      one worker
journalctl --merge -f                                        master and workers together
```

Because full build output goes through journald and journal-upload, size the
master's `journal-remote.conf` limits and the workers' `SystemMaxUse` for it;
large builds such as browsers produce hundreds of megabytes of log.

There is no authentication on the plain-HTTP listener, so bind it to the
master's VPC address only, with a drop-in for the socket:

```
# /etc/systemd/system/systemd-journal-remote.socket.d/vpc.conf
[Socket]
ListenStream=
ListenStream=<private ip>:19532
```

and keep port 19532 closed in the Digital Ocean cloud firewall.

## Operating it

```
archci-status                       queue counts, running builds, recent failures
archci-status --json                queue/outstanding as JSON
archci-next                         what the next claim would build
journalctl -t archci-job -f         every claim/report on the master
journalctl -u archci-scan           scan results
journalctl -u archci-stage          staging to R2
archci-job enqueue extra firefox    build the current release now (priority 0)
archci-job retry <jobid>            reset attempts of a failed job and requeue
archci-job requeue <jobid>          put a running/failed job back, keep attempts
archci-stage --force                move pooled packages to R2 staging now
archci-build job.file /tmp/out      reproduce a build by hand on a worker (root)

# on the signer
archci-sign --unlock                cache the release passphrase for the session
archci-sign                         sign and publish staged packages now
journalctl -u archci-sign -f        release-signing activity
archci-authorize-builder key.pub    trust a worker's builder key
```

All knobs are in `archci.conf.example`. Environment variables override the
file, which is how `test/queue-test.sh` runs the whole master side (scan, claim,
heartbeat, report, reap, forced ssh command and rrsync upload) in a temp dir
without network or root.

## Notes and limits

- Nothing is queued up front: with an empty `built/`, every package in
  `ARCHCI_REPOS` (about 8,200 for core+extra) is outstanding and gets built
  in repo order, then name order, as workers ask for work.
- Packages are built independently against the official mirrors. If the
  mirror the worker uses lags behind the state repo, a build that needs the
  newer dependency fails and is retried later.
- Upstream source PGP signatures are not verified (`ARCHCI_MAKEPKG_ARGS`
  defaults to `--skippgpcheck`): there is no central keyring of packagers'
  upstream keys, so a rebuild farm cannot check them. The build is still
  pinned to the packaging repo's exact commit and the PKGBUILD sha256sums.
  Clear the setting and seed the build user's keyring to enforce them.
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
- Worker ssh keys are shared secrets; rotate by running `archci-authorize` with
  a new key and deleting the old line from `~archci/.ssh/authorized_keys`.
