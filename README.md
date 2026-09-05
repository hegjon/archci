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
 gitlab.archlinux.org                       Cloudflare R2
   packaging/state ──git pull──┐              ▲ rclone (packages first, then dbs, logs, status.json)
   packaging/packages/*        │              │
        │                      ▼              │
        │              ┌───────────────── master ────────────────┐
        │              │ archci-scan   (timer)  state → queue    │
        │              │ archci-job    (ssh)    claim/heartbeat/ │
        │              │                        report → repo-add│
        │              │ archci-job reap (timer) stale/retry     │
        │              │ archci-publish (timer) repo/ → R2       │
        │              └───────▲──────────────────────▲──────────┘
        │        ssh "claim" / "report"       rsync (rrsync-jailed)
        │                      │                      │
        ▼              ┌───────┴────── worker ────────┴──────────┐
   git fetch <commit>  │ archci-worker@N  loop: claim → build → │
                       │ archci-build     mkarchroot/makechrootpkg│
                       │                  (btrfs snapshot per job)│
                       └──────────────────────────────────────────┘
```

## How it works

**Scanning.** `archci-scan` (ruby, every 10 min) pulls the state repo. Each file
`<repo>-<arch>/<pkgbase>` there holds `pkgbase version tag commit`. It compares
that with `built/<repo>-<arch>/<pkgbase>` (`version commit` of the last
successful build) and writes a job file into `queue/pending/` for every
difference. Updates to packages already in our repo get priority 1, the
never-built backlog priority 5, manual enqueues 0. A newer release replaces a
pending or failed job for the same package; a running one is left alone.

**Workers.** `archci-worker@N` runs `ssh master claim <host>-N`. The master's
forced command (`archci-shell`) moves the first pending job to `running/`,
stamps the worker name and attempt, and prints it. The worker then:

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
4. takes the build's journal as `build.log`, and rsyncs it with the packages
   and makepkg logs to `incoming/<jobid>/` on the master (the ssh key is
   jailed to that directory by `rrsync`),
5. reports `success` or `failure`. The verdict comes from a `result` file
   `archci-build` writes last, not from the unit's exit status, because
   systemd counts SIGTERM (a timeout, a stop) as a clean exit.

While building, a background loop sends a heartbeat every 5 minutes. A job
without a heartbeat for 30 minutes is put back in `pending/` by the reaper, so
a worker can be destroyed at any time. On `systemctl stop` the worker reports
`abandoned`, which requeues without counting an attempt.

**Master.** On `report success` the packages are moved into
`repo/<repo>/os/<arch>/`, added with `repo-add -R` (debug packages go to
`<repo>-debug`), and the built record is written. Failures keep their log
under `logs/<repo>/<pkgbase>/<version>/attempt-N.log` and are retried after
3 hours, up to 3 attempts. `archci-publish` (root, every 5 min, only when
something changed) optionally snapshots `repo/`, then uploads packages before
databases so clients never see a dangling db entry, then logs and
`status.json`.

Builds use dependencies from the official Arch mirrors, not from our own
output, so packages can be built in any order and workers stay simple. Point
the chroot at our R2 repo instead by adding it to a copy of
`/usr/share/devtools/pacman.conf.d/extra.conf` if you want a self-hosting
rebuild.

## Source layout

```
lib/      archci-common.sh (bash) and archci.rb (ruby): config, job files, paths
master/   archci-scan, archci-job, archci-shell, archci-authorize, archci-publish, archci-status
worker/   archci-worker, archci-build
systemd/  scan, reaper and publish timers (master); archci-worker@.service and
          archci-build@.service (worker); journal-remote drop-ins for the master
```

`install.sh` copies `lib/` plus the role's directory to `/usr/local/lib/archci`
with the same layout and symlinks the role's scripts into `/usr/local/bin`.

## Layout on the master (`/var/lib/archci`)

```
state/                      clone of packaging/state
queue/{pending,running,done,failed}/<jobid>.job
built/<repo>-<arch>/<pkgbase>     "version commit" of the last good build
incoming/<jobid>/           worker uploads (btrfs subvolume, rrsync jail)
repo/<repo>/os/<arch>/      the pacman repo that gets published (btrfs subvolume)
logs/<repo>/<pkgbase>/<version>/attempt-N.log
snapshots/repo-<timestamp>  read-only snapshots taken before each publish
status.json                 what archci-status --json printed last
```

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
subvolumes when the filesystem allows), and enables the scan, reaper and
publish timers. Then:

1. Create an R2 bucket with a public custom domain and an API token, and write
   `/etc/archci/rclone.conf` (mode 600):

   ```
   [r2]
   type = s3
   provider = Cloudflare
   access_key_id = ...
   secret_access_key = ...
   endpoint = https://<account-id>.r2.cloudflarestorage.com
   ```

2. Edit `/etc/archci/archci.conf`: `ARCHCI_RCLONE_REMOTE="r2:<bucket>"`,
   `ARCHCI_REPOS`, optionally `ARCHCI_GPGKEY`.

3. Authorize worker keys: `archci-authorize worker_key.pub`. This appends
   `command="/usr/local/lib/archci/master/archci-shell",restrict <key>` to the archci
   user's `authorized_keys`, so a worker key can do nothing but the protocol.

Clients then use:

```
[core]
Server = https://<r2 domain>/$repo/os/$arch
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

Keep port 19532 on the master reachable from the VPC only (Digital Ocean
cloud firewall or the droplet's own firewall); there is no authentication on
the plain-HTTP listener.

## Operating it

```
archci-status                       queue counts, running builds, recent failures
archci-status --json                same as published to R2 as status.json
journalctl -t archci-job -f         every claim/report on the master
journalctl -u archci-scan           scan results
journalctl -u archci-publish        uploads
archci-job enqueue extra firefox    build the current release now (priority 0)
archci-job retry <jobid>            reset attempts of a failed job and requeue
archci-job requeue <jobid>          put a running/failed job back, keep attempts
archci-publish --force              push even if nothing changed
archci-build job.file /tmp/out      reproduce a build by hand on a worker (root)
```

All knobs are in `archci.conf.example`. Environment variables override the
file, which is how `test/queue-test.sh` runs the whole master side (scan, claim,
heartbeat, report, reap, forced ssh command and rrsync upload) in a temp dir
without network or root.

## Notes and limits

- The first scan enqueues every package in `ARCHCI_REPOS` (about 13,000 for
  core+extra). Order is priority, then enqueue time, then name.
- Packages are built independently against the official mirrors. If the
  mirror the worker uses lags behind the state repo, a build that needs the
  newer dependency fails and is retried later.
- Nothing is signed unless `ARCHCI_GPGKEY` is set on the master (the key has
  to be usable by root without a passphrase prompt).
- `repo-add -R` keeps only the current version of each package in `repo/`;
  older versions live on in the btrfs snapshots until pruned.
- Worker ssh keys are shared secrets; rotate by running `archci-authorize` with
  a new key and deleting the old line from `~archci/.ssh/authorized_keys`.
