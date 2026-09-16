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

That journal is where every job's log lives: nothing of a build's output
is copied to a file. `archci jobs`, `archci failed`, `archci web log` and
the web front end read a job's log as its entries there, a build's unit
(`archci-build@<repo>-<pkgbase>-<version>-<arch>-a<attempt>`) on its
worker's host, or the sourcer service on its host for a src job, between
the job's claim and its report (two minutes of slack each way; a finished
job keeps `claimed=` for it). A running job's log is what has streamed so
far, polled by cursor. The report reads the log once and keeps its first
error line and its last in the job file (`error=`, `last=`), which is what
the listings print, so `archci failed | cat` does not read the journal per
job. `journal-remote.conf` sets no size or file-count cap, so the journal
keeps every log and grows to fill the volume, vacuuming the oldest only to
keep `KeepFree` (5 GB) free; a log is gone once its entries are vacuumed,
so the volume is the retention, and it shares the volume with the queue,
the pool and makepkg's logs under `logs/`. Since every worker arrives from
127.0.0.1 they share one `archci-workers.journal` file, so select a worker
with `_HOSTNAME=`.

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

## The signing pipeline

The signer never receives a connection: every minute it asks the master over
ssh what waits for a release signature, fetches those files, verifies their
builder signatures, signs and returns the signatures (`archci-sign.timer`);
`archci-publish.timer` on the master (every minute) verifies what came back
with the release public key, indexes it into the master's databases and
publishes to R2. So the master sees the whole pipeline in its own state:
what waits in the pool for the signer, what the signer parked (`<file>.rejected`),
and what each database holds. `archci top` shows it as

```
released: x86_64 63 pkg  aarch64 87 pkg  riscv64 80 pkg
unsigned: 2 pkg in the pool (oldest 1m30s)   rejected by the signer: 1
```

A growing unsigned count with an ageing oldest file means the signer is not
draining it (timer stopped, key locked, cannot reach the master):
`journalctl -u archci-sign` and `journalctl -u archci-sign-health` on the
signer say which, and the health warnings stream to the master's journal. A
count that drains while `released` stops growing means the publish fails:
`journalctl -u archci-publish` on the master. `archci unsigned 0` lists what
waits; a rejected file's reason is beside it in the pool.
