#!/bin/bash
# install.sh master|worker|signer [--arch ARCH] -- install archci on this
# Arch/Omarchy machine. --arch sets ARCHCI_ARCH in /etc/archci/archci.conf; a
# worker whose arch differs from the machine's builds under qemu user-mode
# emulation, and this script sets that up (see README "Building for arm64").
set -euo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
usage() { echo "usage: $0 master|worker|signer [--arch ARCH]" >&2; exit 2; }
role=${1:-}
[[ $role == master || $role == worker || $role == signer ]] || usage
shift
arch_opt=''
while (( $# )); do
	case $1 in
		--arch) arch_opt=${2:-}; [[ $arch_opt =~ ^[a-z0-9_]{1,32}$ ]] || usage; shift 2 ;;
		*) usage ;;
	esac
done
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

# Same layout as the source tree: lib/ is shared, master/ or worker/ per role,
# arch/ holds chroot configs for arches devtools has none for (worker).
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
if [[ ! -e /etc/archci/archci.conf ]]; then
	install -m 644 archci.conf.example /etc/archci/archci.conf
	echo "    wrote /etc/archci/archci.conf -- edit it"
fi
if [[ -n $arch_opt ]]; then
	if grep -q '^ARCHCI_ARCH=' /etc/archci/archci.conf; then
		sed -i "s/^ARCHCI_ARCH=.*/ARCHCI_ARCH=$arch_opt/" /etc/archci/archci.conf
	else
		printf 'ARCHCI_ARCH=%s\n' "$arch_opt" >>/etc/archci/archci.conf
	fi
	echo "    set ARCHCI_ARCH=$arch_opt in /etc/archci/archci.conf"
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
	echo "==> master: sshd reads worker keys from /etc/archci/authorized_keys"
	install -D -m 644 ssh/sshd_config.d/archci.conf /etc/ssh/sshd_config.d/archci.conf
	if [[ ! -e /etc/archci/authorized_keys && -f /var/lib/archci/.ssh/authorized_keys ]]; then
		install -m 644 /var/lib/archci/.ssh/authorized_keys /etc/archci/authorized_keys
		mv /var/lib/archci/.ssh/authorized_keys /var/lib/archci/.ssh/authorized_keys.migrated
		echo "    moved the existing keys from /var/lib/archci/.ssh/authorized_keys"
	fi
	systemctl reload sshd 2>/dev/null || true
	echo "==> master: systemd timers"
	install -m 644 systemd/archci-scan.* systemd/archci-reaper.* systemd/archci-stage.* "$unitdir/"
	echo "==> master: receive worker journals (systemd-journal-remote on port 19532)"
	install -D -m 644 systemd/systemd-journal-remote.service.d/archci.conf "$unitdir/systemd-journal-remote.service.d/archci.conf"
	install -D -m 644 systemd/journal-remote.conf /etc/systemd/journal-remote.conf.d/archci.conf
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
	source lib/archci-common.sh
	echo "==> worker: packages"
	pacman -S --needed --noconfirm devtools git rsync openssh btrfs-progs
	if [[ $ARCHCI_ARCH != "$(uname -m)" ]]; then
		# A foreign arch: makechrootpkg runs the aarch64 (etc.) chroot through
		# qemu user-mode emulation. Needs the binfmt handler registered with the
		# F flag (qemu-user-static-binfmt does that), a setarch alias because
		# arch-nspawn runs "setarch $CARCH" and setarch rejects a foreign name,
		# and a chroot pacman.conf that pins Architecture and points at a repo
		# of that arch (devtools' includes the host's mirrorlist), whose key the
		# host keyring must trust since mkarchroot copies host trust into the chroot.
		echo "==> worker: $ARCHCI_ARCH on a $(uname -m) host: qemu user-mode emulation"
		pacman -S --needed --noconfirm qemu-user-static qemu-user-static-binfmt
		# The same files the archci-worker-qemu-<arch> package installs (PKGBUILD):
		# the stock binfmt registration has flags F and P; the shipped copy adds C
		# so setuid binaries in the chroot keep their privileges (makepkg runs
		# "sudo pacman" to install build dependencies; without C, sudo sees a
		# non-root effective uid). arch-nspawn runs "setarch $CARCH", which
		# rejects a foreign name unless a devtools alias maps it.
		qemu_dir=arch/$ARCHCI_ARCH/qemu
		[[ -d $qemu_dir ]] || { echo "no $qemu_dir/ configs for emulating $ARCHCI_ARCH" >&2; exit 1; }
		for f in "$qemu_dir"/binfmt.d/*.conf; do
			[[ -e $f ]] || continue
			install -D -m 644 "$f" "/etc/binfmt.d/${f##*/}"
			echo "    wrote /etc/binfmt.d/${f##*/} (flags +C for setuid in the chroot)"
		done
		systemctl restart systemd-binfmt
		[[ -f /proc/sys/fs/binfmt_misc/qemu-$ARCHCI_ARCH ]] || { echo "no binfmt handler for $ARCHCI_ARCH" >&2; exit 1; }
		grep -qE '^flags: .*C' "/proc/sys/fs/binfmt_misc/qemu-$ARCHCI_ARCH" || { echo "binfmt handler for $ARCHCI_ARCH lacks the C flag" >&2; exit 1; }
		for f in "$qemu_dir"/setarch-aliases.d/*; do
			[[ -e $f ]] || continue
			install -D -m 644 "$f" "/usr/share/devtools/setarch-aliases.d/${f##*/}"
		done
		if [[ -d $qemu_dir ]]; then
			install -d -m 755 "/etc/archci/$ARCHCI_ARCH"
			for f in "$qemu_dir"/*.conf; do
				[[ -e /etc/archci/$ARCHCI_ARCH/${f##*/} ]] && continue
				install -m 644 "$f" "/etc/archci/$ARCHCI_ARCH/"
				echo "    wrote /etc/archci/$ARCHCI_ARCH/${f##*/} (chroot pacman.conf)"
			done
			for k in "$qemu_dir"/keys/*.asc; do
				[[ -e $k ]] || continue
				fpr=$(gpg --show-keys --with-colons "$k" 2>/dev/null | awk -F: '/^fpr/ { print $10; exit }')
				pacman-key --list-keys "$fpr" >/dev/null 2>&1 && continue
				echo "    trusting the $ARCHCI_ARCH repo key $fpr in the host pacman keyring ($k)"
				pacman-key --add "$k" && pacman-key --lsign-key "$fpr"
			done
		fi
	fi
	echo "==> worker: build user and directories"
	getent passwd archci >/dev/null || useradd --system --home-dir /var/lib/archci-worker --shell /usr/bin/nologin archci
	install -d -m 755 /var/lib/archci-worker /var/lib/archci-worker/jobs /var/lib/archci-worker/build
	install -d -o archci -m 755 /var/lib/archci-worker/srcdest
	echo "==> worker: systemd units (logging to the archci journal namespace)"
	install -m 644 systemd/archci-worker@.service systemd/archci-worker-aarch64@.service \
		systemd/archci-build@.service systemd/archci-worker-setup.service \
		systemd/archci-logging-remote.service "$unitdir/"
	install -D -m 644 systemd/journald@archci.conf /etc/systemd/journald@archci.conf.d/archci.conf
	install -D -m 644 systemd/systemd-journal-upload.service.d/archci.conf \
		"$unitdir/systemd-journal-upload.service.d/archci.conf"
	systemctl daemon-reload
	echo "==> worker: keys, chroot directory, journal streaming (archci-worker-setup)"
	"$libdir/worker/archci-worker-setup"
	systemctl enable archci-worker@1.service
	# Journal streaming is configured by archci-worker-setup from ARCHCI_JOURNAL_URL
	# (a drop-in under /run) and started with the worker; drop the old static drop-in.
	rm -f /etc/systemd/journal-upload.conf.d/archci.conf
	cat <<-MSG

	Worker installed (arch $ARCHCI_ARCH; the master must list it in ARCHCI_ARCHES). Next:
	  1. Make sure "master" resolves to the master's address (/etc/hosts), or
	     change ARCHCI_MASTER in /etc/archci/archci.conf and rerun this script.
	     ARCHCI_JOURNAL_URL: the journal streams to the master (through the ssh
	     tunnel of archci-logging-remote when it is http://127.0.0.1:19532);
	     "" keeps it local.
	  2. Authorize this worker's SSH key on the master (archci-authorize):
	       $(cat /etc/archci/worker_key.pub)
	  3. Trust this worker's BUILDER key on the signer: copy
	       /etc/archci/builder_key.pub
	     to the signer and run  archci-authorize-builder builder_key.pub
	  4. systemctl start archci-worker@1   (add @2, @3 ... for parallel builds;
	     archci-worker-aarch64@1 for an emulated aarch64 instance)
	     journalctl --namespace=archci -u archci-worker@1 -f
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
	install -m 644 systemd/archci-sign.service systemd/archci-sign.timer \
		systemd/archci-sign-health.service systemd/archci-sign-health.timer "$unitdir/"
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
