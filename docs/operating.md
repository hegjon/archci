# Operating it

`archci top` is the live view of the farm, redrawn every few seconds:
the queue, what each host and worker is doing, and the newest failures;
the PHASE and last-output columns follow the workers' streamed journals
live, through one `journalctl -f` for the session.
`archci top --once` prints the frame once and `archci top --json` is the
data behind it for scripts. A frame from the
test instance, four emulated builds running on the desktop and the x86_64
workers idle:

```
archci-top  21:09:10   pkgbuilds -> [hegjon-test]   arches: x86_64 aarch64 riscv64   (q or Esc quits)
queue: pending 9  running 4  failed 55  done 590 (3 in the last hour)    outstanding: 0 update(s), 850 unbuilt
built: x86_64 428/569  aarch64 29/569  riscv64 16/569  any 85/119
released: x86_64 366 pkg  aarch64 152 pkg  riscv64 139 pkg
unsigned: 0 pkg in staging

HOST                   VENDOR        ARCH     LOAD %DISK  %MEM THREADS WORKERS ACTIVE  ARCHCI
master                 DigitalOcean  x86_64   0.12  41.0  23.5       1       0      0  0.3.19-1
jonny-ryzen9           AsrockRack    x86_64  12.35    46    18      32       8      4  0.3.19-1
worker1                DigitalOcean  x86_64   0.57  63.7  32.4       1       1      0  0.3.19-1
worker2                DigitalOcean  x86_64   0.06  57.6  31.9       1       1      0  0.3.19-1

ELAPSED  WORKER              ARCH    ATT   HB  %CPU  DISK   MEM  PEAK  PHASE    SOURCE   PACKAGE  | last output
03:12:00 jonny-ryzen9-a1     aarch64   1  23s   100  1.9G  2.5G  2.6G  check    core     glibc 2.44+r24+g16be1518495f-1 | gc
00:17:05 jonny-ryzen9-a2     aarch64   2  42s   150  271M  632M  714M  prepare  core     coreutils 9.11-2.1 | Creating lib/g
01:04:31 jonny-ryzen9-r1     riscv64   1  57s   100  451M  1.0G  2.9G  check    core     elfutils 0.196-1 | /usr/bin/ld: war
05:31:44 jonny-ryzen9-r2     riscv64   1  49s   100  1.4G  2.0G  9.4G  build    core     binutils 2.47-4 | libtool: compile:

FAILED (newest first)              ARCH     WORKER            FAILURES  GAVE UP  LAST FAILURE
grub 2:2.14-1                      x86_64   worker1-1                3      yes  2026-09-09T21:07:10Z
python-sphinx 9.1.0-1              any      jonny-ryzen9-4           3      yes  2026-09-09T21:06:07Z
brltty 6.9.1-3                     x86_64   jonny-ryzen9-1           3      yes  2026-09-09T21:06:06Z
libadwaita 1:1.9.3-1               x86_64   jonny-ryzen9-2           3      yes  2026-09-09T21:05:34Z
dtc 1:1.8.1-1                      x86_64   worker2-1                3      yes  2026-09-09T21:04:35Z
```

Every command is a subcommand of `archci` (`archci job`, `archci top`, ...;
`archci help` lists the ones installed on a host, and bash completes them,
their options and the queue's job ids). The scripts themselves
live under `/usr/lib/archci/<role>/`, where the units run them. The other
operator commands:

```
archci version                      the installed archci version
archci top --once                  the frame once, without the journal columns: instant
archci top --json                   the frame's data as JSON
archci next                         what the next claim would build
journalctl -t archci-job -f         every claim/report on the master
journalctl -u archci-scan           scan results
journalctl -u archci-stage          staging to R2
archci job enqueue extra firefox    build the current release now (priority 0)
archci top                          live view: workers' load and memory, running
                                    jobs with phase and last output, failures
archci job retry <jobid>            reset attempts of a failed job and requeue
archci job retry --all              the same for every failed job (also -a)
archci job requeue <jobid>          put a running/failed job back, keep attempts
archci stage --force                move pooled packages to R2 staging now
archci build job.file /tmp/out      reproduce a build by hand on a worker (root)

# on the signer
archci sign --unlock                cache the release passphrase for the session
archci sign                         sign and publish staged packages now
journalctl -u archci-sign -f        release-signing activity
journalctl -u archci-sign-health    stall alerts (locked key, staging backlog)
archci authorize-builder key.pub    trust a worker's builder key
```

All knobs are listed with their defaults in `config/archci.conf.example`
(installed as `/usr/share/doc/archci/archci.conf.example`); set the ones you
change in `/etc/archci/archci.conf`. Environment variables override the
file, which is how the tests run without network or root. Run them with
`test/run.sh` (add a name substring to filter, e.g. `test/run.sh lint`);
the PKGBUILD's `check()` runs the same suite, so a release that fails a
test does not get built:

- `test/lint-test.sh` — `bash -n` and `ruby -c` on every script, plus
  `shellcheck` when installed.
- `test/scan-test.sh`, `queue-test.sh`, `multiarch-test.sh` — the master side
  on a throwaway state directory (`test/fixture.sh`): scan and the next-package
  pick, claim, heartbeat, report, retries, housekeeping, `archci top`, and more
  than one architecture.
- `test/access-test.sh` — archci-authorize and the forced ssh command with
  its rrsync upload. `test/cli-test.sh` — the `archci` entry point and its
  bash completion.
- `test/signer-test.sh` — the two-stage signing gate with real gpg keys and
  the R2 hand-off (master stage, signer verify, reject, release-sign, publish,
  drain) against a local rclone stand-in.
- `test/worker-test.sh` — archci-worker end to end with ssh, systemctl and the
  build faked: a normal job, a master outage, self-reload. `pool-test.sh`,
  `watchdog-test.sh` and `config-test.sh` cover one function or file each.

## Releasing

A release is a tag `vX.Y.Z` on this repository plus the matching PKGBUILD
in the PKGBUILD repository (`pkgbuilds/archci/` in the fork), which the
farm then builds and publishes like any other package. That PKGBUILD is
this tree's with the tag's version and checksum filled in, generated, never
edited:

```
git tag -a vX.Y.Z -m '...' && git push origin master vX.Y.Z
tools/release-pkgbuild X.Y.Z /path/to/omarchy-pkgs/pkgbuilds/archci
(cd /path/to/omarchy-pkgs && git add pkgbuilds/archci && git commit -m 'archci X.Y.Z' && git push)
```

The generator fetches the tag's tarball from GitHub for its checksum (push
the tag first), sets `pkgver` and `sha256sums`, and copies the `.install`
files; the result must pass `makepkg --printsrcinfo`. The master picks the
fork commit up at its next scan
(`systemctl start archci-scan` to hurry it), and `pacman -Syu` on each host
installs the release once the signer has published it.
