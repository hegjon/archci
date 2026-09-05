#!/bin/bash
# install.sh master|worker -- install archci on this Arch/Omarchy machine.
set -euo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
role=${1:-}
[[ $role == master || $role == worker ]] || { echo "usage: $0 master|worker" >&2; exit 2; }
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

echo "==> installing scripts to $libdir"
install -d -m 755 "$libdir" /etc/archci
install -m 644 bin/archci-common.sh bin/archci.rb "$libdir/"
for f in bin/*; do
	[[ $f == *.sh || $f == *.rb ]] && continue
	install -m 755 "$f" "$libdir/"
	ln -sf "$libdir/${f##*/}" "$bindir/${f##*/}"
done
if [[ ! -e /etc/archci/archci.conf ]]; then
	install -m 644 archci.conf.example /etc/archci/archci.conf
	echo "    wrote /etc/archci/archci.conf -- edit it"
fi

if [[ $role == master ]]; then
	echo "==> master: packages"
	pacman -S --needed --noconfirm git ruby rsync rclone openssh btrfs-progs
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
	install -m 644 systemd/archci-scan.* systemd/archci-reaper.* systemd/archci-publish.* "$unitdir/"
	systemctl daemon-reload
	systemctl enable --now archci-scan.timer archci-reaper.timer archci-publish.timer
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
	  2. Authorize each worker key:  archci-authorize /path/to/worker_key.pub
	  3. Watch:  archci-status,  journalctl -t archci-job -f,  journalctl -u archci-scan
	MSG
else
	echo "==> worker: packages"
	pacman -S --needed --noconfirm devtools git rsync openssh btrfs-progs
	echo "==> worker: build user and directories"
	getent passwd archci >/dev/null || useradd --system --home-dir /var/lib/archci-worker --shell /usr/bin/nologin archci
	install -d -m 755 /var/lib/archci-worker /var/lib/archci-worker/jobs /var/lib/archci-worker/build
	install -d -o archci -m 755 /var/lib/archci-worker/srcdest
	mksubvol /var/lib/archbuild
	if [[ ! -f /etc/archci/worker_key ]]; then
		ssh-keygen -q -t ed25519 -N '' -C "archci-worker@$(hostname -s)" -f /etc/archci/worker_key
	fi
	chmod 600 /etc/archci/worker_key
	echo "==> worker: systemd unit"
	install -m 644 systemd/archci-worker@.service "$unitdir/"
	systemctl daemon-reload
	systemctl enable archci-worker@1.service
	cat <<-MSG

	Worker installed. Next:
	  1. Make sure "master" resolves to the master's private address (/etc/hosts),
	     or change ARCHCI_MASTER in /etc/archci/archci.conf.
	  2. Authorize this key on the master (archci-authorize):
	       $(cat /etc/archci/worker_key.pub)
	  3. systemctl start archci-worker@1   (add @2, @3 ... for parallel builds)
	     journalctl -u archci-worker@1 -f
	MSG
fi
