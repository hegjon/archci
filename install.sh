#!/bin/bash
# install.sh master|worker|signer -- install archci on this Arch/Omarchy machine.
#
# Two ways in. From a source checkout, the files are copied to /usr/local
# first. From the archci package (PKGBUILD), where this script is
# /usr/bin/archci-setup, the files and units are already in place under
# /usr/lib/archci and /usr/lib/systemd/system, and only the role setup runs:
# packages, user, directories, keys, timers.
set -euo pipefail
self=$(readlink -f "${BASH_SOURCE[0]}")
cd "$(dirname "$self")"
role=${1:-}
[[ $role == master || $role == worker || $role == signer ]] || { echo "usage: ${0##*/} master|worker|signer" >&2; exit 2; }
(( EUID == 0 )) || { echo "run as root" >&2; exit 1; }

if [[ $self == /usr/lib/archci/install.sh ]]; then
	packaged=1
	libdir=/usr/lib/archci
	bindir=/usr/bin
else
	packaged=0
	libdir=/usr/local/lib/archci
	bindir=/usr/local/bin
fi
unitdir=/etc/systemd/system

# install_unit FILE... -> into $unitdir, unless the package already ships them.
install_unit() {
	(( packaged )) && return 0
	install -m 644 "$@" "$unitdir/"
}

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

# Same layout as the source tree: lib/ is shared, master/ or worker/ per role,
# arch/ holds chroot configs for arches devtools has none for (worker).
if (( packaged )); then
	echo "==> archci is installed as a package under $libdir"
	install -d -m 755 /etc/archci
else
	echo "==> installing lib/ and $role/ to $libdir"
	install -d -m 755 "$libdir/lib" "$libdir/$role" /etc/archci
	install -m 644 lib/* "$libdir/lib/"
	for f in "$role"/*; do
		install -m 755 "$f" "$libdir/$role/"
		ln -sf "$libdir/$role/${f##*/}" "$bindir/${f##*/}"
	done
	if [[ $role == worker ]]; then
		rm -rf "$libdir/arch"
		cp -r arch "$libdir/arch"
		chmod -R u=rwX,go=rX "$libdir/arch"
	fi
fi
if [[ ! -e /etc/archci/archci.conf ]]; then
	install -m 644 archci.conf.example /etc/archci/archci.conf
	echo "    wrote /etc/archci/archci.conf -- edit it"
fi

if [[ $role == master ]]; then
	source lib/archci-common.sh
	echo "==> master: packages"
	pacman -S --needed --noconfirm git ruby jq rsync rclone openssh btrfs-progs libmicrohttpd python
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
	install_unit systemd/archci-scan.* systemd/archci-reaper.* systemd/archci-stage.*
	echo "==> master: receive worker journals (systemd-journal-remote on port 19532)"
	if (( ! packaged )); then
		install -D -m 644 systemd/systemd-journal-remote.service.d/archci.conf "$unitdir/systemd-journal-remote.service.d/archci.conf"
		install -D -m 644 systemd/journal-remote.conf /etc/systemd/journal-remote.conf.d/archci.conf
	fi
	systemctl daemon-reload
	systemctl enable --now archci-scan.timer archci-reaper.timer archci-stage.timer
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
	     and set ARCHCI_R2_STAGING="r2:<bucket>/staging" in /etc/archci/archci.conf.
	     Ideally use a token that can only write the staging prefix.
	     ARCHCI_PKGBUILDS_URL there is the repository of PKGBUILDs to build
	     (default $ARCHCI_PKGBUILDS_URL).
	  2. The master holds NO signing key and builds no database. It moves built
	     packages to STAGING; the signer verifies, signs and publishes them.
	  3. Authorize each worker SSH key:  archci-authorize /path/to/worker_key.pub
	     (The signer needs no SSH access to the master; it uses R2.)
	  4. Watch:  archci-status,  journalctl -u archci-stage,  journalctl -t archci-job -f
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
	install -d -m 700 "$ARCHCI_BUILDER_GNUPGHOME"
	if ! gpg --homedir "$ARCHCI_BUILDER_GNUPGHOME" --batch --list-secret-keys "archci-builder@${HOSTNAME%%.*}" >/dev/null 2>&1; then
		gpg --homedir "$ARCHCI_BUILDER_GNUPGHOME" --batch --pinentry-mode loopback --passphrase "" --quick-generate-key \
			"archci builder ${HOSTNAME%%.*} <archci-builder@${HOSTNAME%%.*}>" ed25519 sign never
	fi
	gpg --homedir "$ARCHCI_BUILDER_GNUPGHOME" --batch --yes --armor \
		--export "archci-builder@${HOSTNAME%%.*}" >/etc/archci/builder_key.pub
	echo "==> worker: systemd unit"
	install_unit systemd/archci-worker@.service systemd/archci-build@.service
	echo "==> worker: stream the journal to the master (systemd-journal-upload)"
	source lib/archci-common.sh
	install -d -m 755 /etc/systemd/journal-upload.conf.d
	printf '[Upload]\nURL=%s\n' "$ARCHCI_JOURNAL_URL" >/etc/systemd/journal-upload.conf.d/archci.conf
	systemctl daemon-reload
	systemctl enable archci-worker@1.service
	systemctl enable --now systemd-journal-upload.service
	if [[ $ARCHCI_ARCH != "$(uname -m)" ]]; then
		echo "WARNING: ARCHCI_ARCH=$ARCHCI_ARCH but this machine is $(uname -m); set ARCHCI_ARCH in /etc/archci/archci.conf" >&2
	fi
	cat <<-MSG

	Worker installed (arch $ARCHCI_ARCH; the master must list it in ARCHCI_ARCHES). Next:
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
	pacman -S --needed --noconfirm git rclone gnupg
	source lib/archci-common.sh
	echo "==> signer: user, directories and keyrings"
	getent passwd archci >/dev/null || useradd --system --home-dir "$ARCHCI_SIGNER_HOME" --shell /usr/bin/nologin archci
	install -d -m 755 "$ARCHCI_SIGNER_HOME" "$ARCHCI_SIGNER_HOME/work" "$ARCHCI_SIGNER_HOME/repo"
	install -d -m 700 "$ARCHCI_RELEASE_GNUPGHOME" "$ARCHCI_BUILDER_KEYRING"
	# Cache the release passphrase for a day so the timer can sign after one unlock.
	if [[ ! -f $ARCHCI_RELEASE_GNUPGHOME/gpg-agent.conf ]]; then
		printf 'default-cache-ttl 86400\nmax-cache-ttl 86400\nallow-loopback-pinentry\n' \
			>"$ARCHCI_RELEASE_GNUPGHOME/gpg-agent.conf"
	fi
	echo "==> signer: systemd timers"
	install_unit systemd/archci-sign.service systemd/archci-sign.timer \
		systemd/archci-sign-health.service systemd/archci-sign-health.timer
	systemctl daemon-reload
	systemctl enable archci-sign.timer archci-sign-health.timer
	cat <<-MSG

	Signer installed. It talks only to R2, never to the master. Next:
	  1. Put the R2 credentials in /etc/archci/rclone.conf (chmod 600) and set,
	     in /etc/archci/archci.conf:
	       ARCHCI_R2_STAGING="r2:<bucket>/staging"   (read; the master writes it)
	       ARCHCI_R2_RELEASE="r2:<bucket>"           (write; clients read it)
	     Ideally a token that can read staging and write the release prefix.
	  2. Create the passphrase-protected release key once:
	       gpg --homedir $ARCHCI_RELEASE_GNUPGHOME --full-generate-key
	     Match ARCHCI_RELEASE_KEY (default archci-release). Export the PUBLIC key:
	       gpg --homedir $ARCHCI_RELEASE_GNUPGHOME --armor --export archci-release >/etc/archci/release.pub
	     Clients:  pacman-key --add release.pub && pacman-key --lsign-key <fingerprint>
	  3. Trust each worker's builder key:  archci-authorize-builder builder_key.pub
	  4. Unlock the release key and start signing:
	       archci-sign --unlock
	       systemctl start archci-sign.timer
	     journalctl -u archci-sign -f
	MSG
fi
