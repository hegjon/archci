# Monitoring workers from the master

Workers stream the `archci` journal namespace, and nothing else of their
journal, to the master with `systemd-journal-upload --namespace=archci`,
through an ssh tunnel over the worker key: `archci-logging-tunnel.service`
holds `ssh -N -L 127.0.0.1:19533:127.0.0.1:19533 archci@master` open, and
the upload goes to `http://127.0.0.1:19533`, the default `ARCHCI_JOURNAL_URL`
(`""` streams nothing; `archci-logging-setup` of the archci-remote-logging
package configures both on every start, on workers and the sourcer alike).
The master's receiver, `archci-journal-remote.service` running
`systemd-journal-remote`, binds 127.0.0.1:19533 only, so the plain-HTTP journal port is never
exposed, inside the VPC or out, and a worker needs nothing but ssh to the
master, from anywhere. The master allows a worker key to forward to this one
port and nothing else (`archci-authorize` writes `port-forwarding,permitopen=...`
after `restrict`, and the sshd drop-in adds `PermitOpen`), and with `-N` no
session is opened, so the forced command never runs. Same direction as the
job protocol, and the last lines of a worker that died are already on the
master. journal-remote keeps the received journals under
`/var/lib/archci/journal/` (on the archci volume, not the root disk).
`journal-remote.conf` sets no size or file-count cap, so the journal keeps
every build's log and grows to fill the volume, vacuuming the oldest only
to keep `KeepFree` (5 GB) free; it shares the volume with the queue, the
pool and the text logs under `logs/`, so those and the journal compete for
the space. Since every worker arrives from 127.0.0.1 they share one
`archci-workers.journal` file, so select a worker with `_HOSTNAME=`.

```
journalctl -D /var/lib/archci/journal -f                     all workers, live
journalctl -D /var/lib/archci/journal -u 'archci-worker@*'   the worker loops only
journalctl -D /var/lib/archci/journal -u 'archci-build@*'    every build's output
journalctl -D /var/lib/archci/journal -u archci-build@core-linux-7.2.3.arch1-2-a1
journalctl -D /var/lib/archci/journal _HOSTNAME=worker1      one worker
journalctl -D /var/lib/archci/journal -D /var/log/journal -f  master and workers together
```

Because full build output goes through journald and journal-upload, the
master's journal fills the archci volume down to `KeepFree`; watch the disk,
and lower `journal-remote.conf`'s `KeepFree` or add a `MaxUse` if the queue
and pool need more room. A worker's own `journald@archci.conf` `SystemMaxUse`
(4 GB) bounds its local buffer, which matters only while the master is
unreachable, since upload is live. Large builds such as browsers produce
hundreds of megabytes of log.

## The signer, through R2

The signer never talks to the master: it takes packages from staging and
publishes the released repo, both on R2. What the master can see is the
release pipeline as a client sees it. `archci-signer-status.timer` (every 2
minutes) lists staging with the master's rclone token and fetches each
arch's released database over `ARCHCI_RELEASE_URL`, the clients' repo URL,
then writes `/var/lib/archci/signer.status`. `archci top`
shows it as

```
released: x86_64 63 pkg  aarch64 87 pkg  riscv64 80 pkg
unsigned: 2 pkg in staging (oldest 1m30s)
```

A growing staging backlog with an ageing oldest package means the signer is
not draining it (timer stopped, key locked); a database that stops updating
while packages leave staging means publishing fails. Whether the release key
is locked is known only on the signer: `journalctl -u archci-sign-health`
there.
