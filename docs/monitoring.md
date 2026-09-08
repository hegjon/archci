# Monitoring workers from the master

Workers stream the `archci` journal namespace, and nothing else of their
journal, to the master with `systemd-journal-upload --namespace=archci`,
through an ssh tunnel over the worker key: `archci-logging-remote.service`
holds `ssh -N -L 127.0.0.1:19532:127.0.0.1:19532 archci@master` open, and
the upload goes to `http://127.0.0.1:19532`, the default `ARCHCI_JOURNAL_URL`
(`""` streams nothing; `archci-worker-setup` configures both on every worker
start). The master's `systemd-journal-remote` listens on loopback only (the
master package's socket drop-in), so the plain-HTTP journal port is never
exposed, inside the VPC or out, and a worker needs nothing but ssh to the
master, from anywhere. The master allows a worker key to forward to this one
port and nothing else (`archci-authorize` writes `port-forwarding,permitopen=...`
after `restrict`, and the sshd drop-in adds `PermitOpen`), and with `-N` no
session is opened, so the forced command never runs. Same direction as the
job protocol, and the last lines of a worker that died are already on the
master. journal-remote keeps the received journals under
`/var/log/journal/remote/`, capped by `journal-remote.conf` (2 GB, 200
files); since every worker arrives from 127.0.0.1 they share one
`remote-127.0.0.1.journal` file, so select a worker with `_HOSTNAME=`.

```
journalctl -D /var/log/journal/remote -f                     all workers, live
journalctl -D /var/log/journal/remote -u 'archci-worker@*'   the worker loops only
journalctl -D /var/log/journal/remote -u 'archci-build@*'    every build's output
journalctl -D /var/log/journal/remote -u archci-build@core-linux-7.2.3.arch1-2-a1
journalctl -D /var/log/journal/remote _HOSTNAME=worker1      one worker
journalctl --merge -f                                        master and workers together
```

Because full build output goes through journald and journal-upload, size the
master's `journal-remote.conf` limits and the workers' `journald@archci.conf`
`SystemMaxUse` for it; large builds such as browsers produce hundreds of
megabytes of log.
