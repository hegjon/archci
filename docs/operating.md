# Operating it

`archci-status` is the at-a-glance view of the farm. A live example from the
prototype, part way through building `core`:

```
archci master status  (2026-09-06T08:34:59Z)

  queue: pending=0  running=2  done=94  failed=11
  outstanding: 0 update(s), 8158 unbuilt
  built: core 51/177  extra 0/8045

  running:
    core/guile 3.0.11-1                      worker1-1            attempt 1  heartbeat 2m ago
    core/kmod 34.2-1                         worker2-1            attempt 1  heartbeat 2m ago

  failed (11, newest first):
    core/grub 2:2.14-1                       worker2-1            attempt 1
    core/gnutls 3.8.13-2                     worker1-1            attempt 1
    core/gpm 1.20.7.r38.ge82d1a6-6           worker2-1            attempt 1
    core/gcc 16.2.1+r23+gd564253eb6c8-1      worker2-1            attempt 3  GAVE UP
    core/glibc 2.44+r24+g16be1518495f-1      worker1-1            attempt 1
    core/gettext 1.0-2                       worker2-1            attempt 1
    core/elfutils 0.196-1                    worker1-1            attempt 3  GAVE UP
    core/dmraid 1.0.0.rc16.3-15              worker1-1            attempt 3  GAVE UP
    core/curl 8.22.0-1                       worker1-1            attempt 3  GAVE UP
    core/coreutils 9.11-2                    worker1-1            attempt 3  GAVE UP
    core/bison 3.8.2-8                       worker1-1            attempt 3  GAVE UP

  recently built:
    core/keyutils 1.6.3-4                    worker2-1            2026-09-06T08:33:00Z
    core/kbd 2.10.0-1                        worker2-1            2026-09-06T08:32:31Z
    core/json-c 0.19-1                       worker2-1            2026-09-06T08:30:18Z
    core/jfsutils 1.1.15-9                   worker2-1            2026-09-06T08:28:59Z
    core/jansson 2.15.1-1                    worker2-1            2026-09-06T08:28:01Z
    core/iw 6.17-1                           worker2-1            2026-09-06T08:27:14Z
    core/iputils 20250605-1                  worker2-1            2026-09-06T08:26:38Z
    core/iptables 1:1.8.13-1                 worker2-1            2026-09-06T08:25:58Z
    core/iproute2 7.2.0-1                    worker2-1            2026-09-06T08:22:47Z
    core/inetutils 2.8-1                     worker2-1            2026-09-06T08:18:52Z
```

The other operator commands:

```
archci-status                       queue counts, running builds, recent failures
archci-status --json                queue/outstanding as JSON
archci-next                         what the next claim would build
journalctl -t archci-job -f         every claim/report on the master
journalctl -u archci-scan           scan results
journalctl -u archci-stage          staging to R2
archci-job enqueue extra firefox    build the current release now (priority 0)
archci-top                          live view: workers' load and memory, running
                                    jobs with phase and last output, failures
archci-job retry <jobid>            reset attempts of a failed job and requeue
archci-job requeue <jobid>          put a running/failed job back, keep attempts
archci-stage --force                move pooled packages to R2 staging now
archci-build job.file /tmp/out      reproduce a build by hand on a worker (root)

# on the signer
archci-sign --unlock                cache the release passphrase for the session
archci-sign                         sign and publish staged packages now
journalctl -u archci-sign -f        release-signing activity
journalctl -u archci-sign-health    stall alerts (locked key, staging backlog)
archci-authorize-builder key.pub    trust a worker's builder key
```

All knobs are in `config/archci.conf`, installed as `/etc/archci/archci.conf`. Environment variables override the
file, which is how the tests run without network or root. Run them with
`test/run.sh` (add a name substring to filter, e.g. `test/run.sh lint`):

- `test/lint-test.sh` — `bash -n` and `ruby -c` on every script, plus
  `shellcheck` when installed.
- `test/integration-test.sh` — the whole master side (scan, claim, heartbeat,
  report, reap, forced ssh command, rrsync upload), the two-stage signing gate
  with real gpg keys, and the R2 hand-off (master stage, signer verify, reject,
  release-sign, publish, drain) against a local rclone stand-in, in a temp dir.
