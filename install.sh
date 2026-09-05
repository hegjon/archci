#!/bin/bash
# install.sh master|worker -- install archci on this Arch/Omarchy machine.
set -euo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
role=${1:-}
[[ $role == master || $role == worker || $role == signer ]] || { echo "usage: $0 master|worker|signer" >&2; exit 2; }
(( EUID == 0 )) || { echo "run as root" >&2; exit 1; }

libdir=/usr/local/lib/archci
bindir=/usr/local/bin
unitdir=/etc/systemd/system

# btrfs subvolume when possible (cheap snapshots), plain directory otherwise.
mksubvol() {
	local dir=$1
	[[ -e $dir ]] && return 0
	if [[ $(stat -f -c %T "$(dirname "$dir")") == btrfs ]]; then
		btrfs subvolume create "$dir" >/dev/null
	else
		mkdir -p "$dir"
	fi
}

# Same layout as the source tree: lib/ is shared, master/ or worker/ per role.
echo "==> installing lib/ and $role/ to $libdir"
install -d -m 755 "$libdir/lib" "$libdir/$role" /etc/archci
install -m 644 lib/* "$libdir/lib/"
for f in "$role"/*; do
	install -m 755 "$f" "$libdir/$role/"
	ln -sf "$libdir/$role/${f##*/}" "$bindir/${f##*/}"
done
if [[ ! -e /etc/archci/archci.conf ]]; then
	install -m 644 archci.conf.example /etc/archci/archci.conf
	echo "    wrote /etc/archci/archci.conf -- edit it"
fi

if [[ $role == master ]]; then
	echo "==> master: packages"
	pacman -S --needed --noconfirm git ruby rsync rclone openssh btrfs-progs libmicrohttpd
	echo "==> master: archci user and directories"
	# A real shell is needed: sshd runs the forced command through it.
	getent passwd archci >/dev/null || useradd --system --home-dir /var/lib/archci --create-home --shell /bin/bash archci
	install -d -o archci -g archci -m 755 /var/lib/archci
	for d in queue/pending queue/running queue/done queue/failed built logs lock; do
		install -d -o archci -g archci -m 755 "/var/lib/archci/$d"
	done
	mksubvol /var/lib/archci/repo
	mksubvol /var/lib/archci/incoming
	chown archci:archci /var/lib/archci/repo /var/lib/archci/incoming
	echo "==> master: systemd timers"
	install -m 644 systemd/archci-scan.* systemd/archci-reaper.* systemd/archci-index.* systemd/archci-publish.* "$unitdir/"
	echo "==> master: receive worker journals (systemd-journal-remote on port 19532)"
	install -D -m 644 systemd/systemd-journal-remote.service.d/archci.conf "$unitdir/systemd-journal-remote.service.d/archci.conf"
	install -D -m 644 systemd/journal-remote.conf /etc/systemd/journal-remote.conf.d/archci.conf
	systemctl daemon-reload
	systemctl enable --now archci-scan.timer archci-reaper.timer archci-index.timer archci-publish.timer
	systemctl enable --now systemd-journal-remote.socket
	cat <<-MSG

	Master installed. Next:
	  1. Put the R2 credentials in /etc/archci/rclone.conf (chmod 600), e.g.
	       [r2]
	       type = s3
	       provider = Cloudflare
	       access_key_id = ...
	       secret_access_key = ...
	       endpoint = https://<account-id>.r2.cloudflarestorage.com
	     and set ARCHCI_RCLONE_REMOTE="r2:<bucket>" in /etc/archci/archci.conf.
	  2. Authorize each worker SSH key:  archci-authorize /path/to/worker_key.pub
	     Authorize the signer SSH key:   archci-authorize --signer /path/to/signer_key.pub
	  3. The master holds NO signing key. Once the signer runs, set ARCHCI_SIGN=1
	     in /etc/archci/archci.conf so only signed packages enter the databases.
	  4. Watch:  archci-status,  journalctl -t archci-job -f,  journalctl -u archci-scan
	     Worker journals:  journalctl -D /var/log/journal/remote -f
	  5. Keep ports 19532 (journal upload) and 22 reachable from the VPC only.
	MSG
elif [[ $role == worker ]]; then
	echo "==> worker: packages"
	pacman -S --needed --noconfirm devtools git rsync openssh btrfs-progs
	echo "==> worker: build user and directories"
	getent passwd archci >/dev/null || useradd --system --home-dir /var/lib/archci-worker --shell /usr/bin/nologin archci
	install -d -m 755 /var/lib/archci-worker /var/lib/archci-worker/jobs /var/lib/archci-worker/build
	install -d -o archci -m 755 /var/lib/archci-worker/srcdest
	mksubvol /var/lib/archbuild
	if [[ ! -f /etc/archci/worker_key ]]; then
		ssh-keygen -q -t ed25519 -N '' -C "archci-worker@${HOSTNAME%%.*}" -f /etc/archci/worker_key
	fi
	chmod 600 /etc/archci/worker_key
	echo "==> worker: builder signing key"
	source lib/archci-common.sh
	if [[ ! -d $ARCHCI_BUILDER_GNUPGHOME ]]; then
		install -d -m 700 "$ARCHCI_BUILDER_GNUPGHOME"
		gpg --homedir "$ARCHCI_BUILDER_GNUPGHOME" --batch --pinentry-mode loopback --passphrase "" --quick-generate-key \
			"archci builder ${HOSTNAME%%.*} <archci-builder@${HOSTNAME%%.*}>" ed25519 sign never
	fi
	gpg --homedir "$ARCHCI_BUILDER_GNUPGHOME" --batch --yes --armor \
		--export "archci-builder@${HOSTNAME%%.*}" >/etc/archci/builder_key.pub
	echo "==> worker: systemd unit"
	install -m 644 systemd/archci-worker@.service systemd/archci-build@.service "$unitdir/"
	echo "==> worker: stream the journal to the master (systemd-journal-upload)"
	source lib/archci-common.sh
	install -d -m 755 /etc/systemd/journal-upload.conf.d
	printf '[Upload]\nURL=%s\n' "$ARCHCI_JOURNAL_URL" >/etc/systemd/journal-upload.conf.d/archci.conf
	systemctl daemon-reload
	systemctl enable archci-worker@1.service
	systemctl enable --now systemd-journal-upload.service
	cat <<-MSG

	Worker installed. Next:
	  1. Make sure "master" resolves to the master's private address (/etc/hosts),
	     or change ARCHCI_MASTER and ARCHCI_JOURNAL_URL in /etc/archci/archci.conf
	     and rerun this script.
	  2. Authorize this worker's SSH key on the master (archci-authorize):
	       $(cat /etc/archci/worker_key.pub)
	  3. Trust this worker's BUILDER key on the signer: copy
	       /etc/archci/builder_key.pub
	     to the signer and run  archci-authorize-builder builder_key.pub
	  4. systemctl start archci-worker@1   (add @2, @3 ... for parallel builds)
	     journalctl -u archci-worker@1 -f
	MSG
elif [[ $role == signer ]]; then
	echo "==> signer: packages"
	pacman -S --needed --noconfirm git rsync openssh gnupg
	source lib/archci-common.sh
	echo "==> signer: user, directories and keyrings"
	getent passwd archci >/dev/null || useradd --system --home-dir "$ARCHCI_SIGNER_HOME" --shell /usr/bin/nologin archci
	install -d -m 755 "$ARCHCI_SIGNER_HOME" "$ARCHCI_SIGNER_HOME/work"
	install -d -m 700 "$ARCHCI_RELEASE_GNUPGHOME" "$ARCHCI_BUILDER_KEYRING"
	# Cache the release passphrase for a day so the timer can sign after one unlock.
	if [[ ! -f $ARCHCI_RELEASE_GNUPGHOME/gpg-agent.conf ]]; then
		printf 'default-cache-ttl 86400\nmax-cache-ttl 86400\nallow-loopback-pinentry\n' \
			>"$ARCHCI_RELEASE_GNUPGHOME/gpg-agent.conf"
	fi
	if [[ ! -f $ARCHCI_SIGNER_KEY ]]; then
		ssh-keygen -q -t ed25519 -N '' -C "archci-signer@${HOSTNAME%%.*}" -f "$ARCHCI_SIGNER_KEY"
	fi
	chmod 600 "$ARCHCI_SIGNER_KEY"
	echo "==> signer: systemd timer"
	install -m 644 systemd/archci-sign.service systemd/archci-sign.timer "$unitdir/"
	systemctl daemon-reload
	systemctl enable archci-sign.timer
	cat <<-MSG

	Signer installed. Next:
	  1. Make sure "master" (or ARCHCI_SIGNER_MASTER) resolves to the master's
	     VPC address in /etc/hosts.
	  2. Create the passphrase-protected release key once:
	       gpg --homedir $ARCHCI_RELEASE_GNUPGHOME --full-generate-key
	     Match ARCHCI_RELEASE_KEY (default archci-release). Export the PUBLIC key:
	       gpg --homedir $ARCHCI_RELEASE_GNUPGHOME --armor --export archci-release >/etc/archci/release.pub
	     Clients:  pacman-key --add release.pub && pacman-key --lsign-key <fingerprint>
	  3. Authorize this signer's SSH key on the master:
	       $(cat "$ARCHCI_SIGNER_KEY.pub")
	     On the master:  archci-authorize --signer /path/to/signer_key.pub
	  4. Trust each worker's builder key:  archci-authorize-builder builder_key.pub
	  5. Unlock the release key and start signing:
	       archci-sign --unlock
	       systemctl start archci-sign.timer
	     journalctl -u archci-sign -f
	MSG
fi
