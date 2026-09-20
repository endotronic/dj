#!/bin/sh
# Deploys zfs-vdev-textfile-collector.sh (same directory -- not itself
# a postinstall hook, just the payload this hook installs) to
# /usr/local/bin and wires it into node_exporter's textfile collector
# the same way the packaged smartmon/nvme collectors are wired: a
# oneshot systemd service run on a timer, writing atomically into the
# textfile collector directory. See that script's own header for why
# it exists (node_exporter's built-in zfs collector has no per-vdev
# error counters or scrub history).
#
# Self-guarding, so it's safe to list in common.txt across a mixed
# fleet: no-ops on hosts without zfs or without systemd.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

command -v zpool >/dev/null 2>&1 || { printf '[postinstall:zfs-textfile-collector] zpool not found; skipping\n' >&2; exit 0; }
command -v systemctl >/dev/null 2>&1 || { printf '[postinstall:zfs-textfile-collector] systemctl not found; skipping\n' >&2; exit 0; }

bin_dest="${DOTFILES_ZFS_COLLECTOR_BIN:-/usr/local/bin/zfs-vdev-textfile-collector.sh}"
unit_dir="${DOTFILES_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
textfile_dir="${DOTFILES_TEXTFILE_COLLECTOR_DIR:-/var/lib/prometheus/node-exporter}"

sudo install -d -m 755 "$(dirname "$bin_dest")"
sudo install -m 755 "$script_dir/zfs-vdev-textfile-collector.sh" "$bin_dest"

sudo tee "$unit_dir/zfs-vdev-textfile-collector.service" >/dev/null <<EOF
[Unit]
Description=Collect ZFS vdev error and scrub metrics for prometheus-node-exporter

[Service]
Type=oneshot
Environment=DOTFILES_TEXTFILE_COLLECTOR_DIR=$textfile_dir
ExecStart=$bin_dest
EOF

sudo tee "$unit_dir/zfs-vdev-textfile-collector.timer" >/dev/null <<'EOF'
[Unit]
Description=Run ZFS vdev/scrub metrics collection every 5 minutes

[Timer]
OnBootSec=0
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now zfs-vdev-textfile-collector.timer

printf '[postinstall:zfs-textfile-collector] installed %s and enabled zfs-vdev-textfile-collector.timer\n' "$bin_dest"
