#!/bin/sh
# Deploys memory-size-textfile-collector.sh (same directory -- not
# itself a postinstall hook, just the payload this hook installs) to
# /usr/local/bin and runs it on a timer, writing the host's physical
# memory size into node_exporter's textfile collector directory. See
# that script's own header for why node_exporter's meminfo isn't
# enough (MemTotal excludes firmware/kernel reservations).
#
# A oneshot on a slow timer rather than a looping service: installed
# memory only changes across a reboot (or a hotplug, which is rare
# enough that an hour's lag is fine).
#
# Self-guarding, so it's safe to list in common.txt across a mixed
# fleet: no-ops without systemd or without a node_exporter textfile
# directory to write into.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

log() { printf '[postinstall:memory-textfile-collector] %s\n' "$1"; }

command -v systemctl >/dev/null 2>&1 || { log 'systemctl not found; skipping' >&2; exit 0; }

bin_dest="${DOTFILES_MEMORY_COLLECTOR_BIN:-/usr/local/bin/memory-size-textfile-collector.sh}"
unit_dir="${DOTFILES_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
textfile_dir="${DOTFILES_TEXTFILE_COLLECTOR_DIR:-/var/lib/prometheus/node-exporter}"
name=memory-size-textfile-collector

[ -d "$textfile_dir" ] || { log "$textfile_dir not found (no node_exporter?); skipping" >&2; exit 0; }

sudo install -d -m 755 "$(dirname "$bin_dest")"
sudo install -m 755 "$script_dir/memory-size-textfile-collector.sh" "$bin_dest"

sudo tee "$unit_dir/$name.service" >/dev/null <<EOF
# Managed by dotfiles (packages/postinstall/memory-textfile-collector.sh).
[Unit]
Description=Collect physical memory size for prometheus-node-exporter

[Service]
Type=oneshot
Environment=DOTFILES_TEXTFILE_COLLECTOR_DIR=$textfile_dir
ExecStart=$bin_dest
EOF

sudo tee "$unit_dir/$name.timer" >/dev/null <<'EOF'
# Managed by dotfiles (packages/postinstall/memory-textfile-collector.sh).
[Unit]
Description=Run physical memory size collection hourly

[Timer]
OnBootSec=0
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now "$name.timer"
# Run now too: on a re-run the timer is already active, so enable
# --now alone wouldn't pick up a changed script until the next tick.
sudo systemctl start "$name.service"

log "installed $bin_dest and enabled $name.timer (hourly -> $textfile_dir/memory_size.prom)"
