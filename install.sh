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
		# The stock registration has flags F and P. Add C so setuid binaries in
		# the chroot keep their privileges (makepkg runs "sudo pacman" to install
		# build dependencies; without C, sudo sees a non-root effective uid).
		bf=/usr/lib/binfmt.d/qemu-$ARCHCI_ARCH-static.conf
		if [[ -f $bf ]] && ! grep -qE ':[A-Z]*C[A-Z]*$' "/etc/binfmt.d/qemu-$ARCHCI_ARCH-static.conf" 2>/dev/null; then
			install -d -m 755 /etc/binfmt.d
			sed -E 's/:([A-Z]*)$/:\1C/' "$bf" >"/etc/binfmt.d/qemu-$ARCHCI_ARCH-static.conf"
			echo "    wrote /etc/binfmt.d/qemu-$ARCHCI_ARCH-static.conf (flags +C for setuid in the chroot)"
		fi
		systemctl restart systemd-binfmt
		[[ -f /proc/sys/fs/binfmt_misc/qemu-$ARCHCI_ARCH ]] || { echo "no binfmt handler for $ARCHCI_ARCH" >&2; exit 1; }
		grep -qE '^flags: .*C' "/proc/sys/fs/binfmt_misc/qemu-$ARCHCI_ARCH" || { echo "binfmt handler for $ARCHCI_ARCH lacks the C flag" >&2; exit 1; }
		alias_file=/usr/share/devtools/setarch-aliases.d/$ARCHCI_ARCH
		[[ -f $alias_file ]] || { echo linux64 >"$alias_file"; echo "    wrote $alias_file (linux64)"; }
		if [[ -d arch/$ARCHCI_ARCH/qemu ]]; then
			install -d -m 755 "/etc/archci/$ARCHCI_ARCH"
			for f in arch/"$ARCHCI_ARCH"/qemu/*.conf; do
				[[ -e /etc/archci/$ARCHCI_ARCH/${f##*/} ]] && continue
				install -m 644 "$f" "/etc/archci/$ARCHCI_ARCH/"
				echo "    wrote /etc/archci/$ARCHCI_ARCH/${f##*/} (chroot pacman.conf)"
			done
			for k in arch/"$ARCHCI_ARCH"/qemu/keys/*.asc; do
				[[ -e $k ]] || continue
				fpr=$(gpg --show-keys --with-colons "$k" 2>/dev/null | awk -F: '/^fpr/ { print $10; exit }')
				pacman-key --list-keys "$fpr" >/dev/null 2>&1 && continue
				echo "    trusting the $ARCHCI_ARCH repo key $fpr in the host pacman keyring ($k)"
				pacman-key --add "$k" && pacman-key --lsign-key "$fpr"
			done
		else
			echo "WARNING: no arch/$ARCHCI_ARCH/qemu/ configs; write /etc/archci/$ARCHCI_ARCH/extra.conf yourself" >&2
		fi
	fi
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
	install -m 644 systemd/archci-worker@.service systemd/archci-build@.service "$unitdir/"
	systemctl daemon-reload
	systemctl enable archci-worker@1.service
	if [[ -n $ARCHCI_JOURNAL_URL ]]; then
		echo "==> worker: stream the journal to the master (systemd-journal-upload to $ARCHCI_JOURNAL_URL)"
		install -d -m 755 /etc/systemd/journal-upload.conf.d
		printf '[Upload]\nURL=%s\n' "$ARCHCI_JOURNAL_URL" >/etc/systemd/journal-upload.conf.d/archci.conf
		systemctl enable --now systemd-journal-upload.service
	else
		# ARCHCI_JOURNAL_URL="" : a worker outside the master's network (the
		# journal port is plain HTTP and not public) keeps its journal local.
		echo "==> worker: ARCHCI_JOURNAL_URL is empty, not streaming the journal"
		systemctl disable --now systemd-journal-upload.service 2>/dev/null || true
		rm -f /etc/systemd/journal-upload.conf.d/archci.conf
	fi
	cat <<-MSG

	Worker installed (arch $ARCHCI_ARCH; the master must list it in ARCHCI_ARCHES). Next:
	  1. Make sure "master" resolves to the master's address (/etc/hosts), or
	     change ARCHCI_MASTER in /etc/archci/archci.conf and rerun this script.
	     Outside the master's private network set ARCHCI_JOURNAL_URL="" too.
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
