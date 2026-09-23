#!/bin/sh
# Deploys nvidia-gpu-textfile-collector.sh (same directory -- not
# itself a postinstall hook, just the payload this hook installs) to
# /usr/local/bin and runs it as a long-lived service writing GPU
# metrics (power draw, temperature, utilization, clocks, per-process
# GPU memory) into node_exporter's textfile collector directory. See
# that script's own header for what's collected and why not DCGM.
#
# A service looping every $interval seconds rather than a timer like
# zfs-textfile-collector's: power draw is only interesting at scrape
# resolution, and a 15s timer logs two journal lines per run forever.
#
# Self-guarding, so it's safe to list in common.txt across a mixed
# fleet: no-ops on hosts without nvidia-smi, without systemd, or
# without a node_exporter textfile directory to write into.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

log() { printf '[postinstall:nvidia-textfile-collector] %s\n' "$1"; }

command -v nvidia-smi >/dev/null 2>&1 || { log 'nvidia-smi not found; skipping' >&2; exit 0; }
command -v systemctl >/dev/null 2>&1 || { log 'systemctl not found; skipping' >&2; exit 0; }

bin_dest="${DOTFILES_NVIDIA_COLLECTOR_BIN:-/usr/local/bin/nvidia-gpu-textfile-collector.sh}"
unit_dir="${DOTFILES_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
textfile_dir="${DOTFILES_TEXTFILE_COLLECTOR_DIR:-/var/lib/prometheus/node-exporter}"
interval="${DOTFILES_NVIDIA_COLLECTOR_INTERVAL:-15}"
unit=nvidia-gpu-textfile-collector.service

[ -d "$textfile_dir" ] || { log "$textfile_dir not found (no node_exporter?); skipping" >&2; exit 0; }

sudo install -d -m 755 "$(dirname "$bin_dest")"
sudo install -m 755 "$script_dir/nvidia-gpu-textfile-collector.sh" "$bin_dest"

sudo tee "$unit_dir/$unit" >/dev/null <<EOF
# Managed by dotfiles (packages/postinstall/nvidia-textfile-collector.sh).
[Unit]
Description=Collect NVIDIA GPU metrics for prometheus-node-exporter

[Service]
Environment=DOTFILES_TEXTFILE_COLLECTOR_DIR=$textfile_dir
ExecStart=$bin_dest --interval $interval
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "$unit" >/dev/null 2>&1 || true
# restart, not start: picks up a changed script or unit on a re-run.
sudo systemctl restart "$unit"

log "installed $bin_dest and (re)started $unit (every ${interval}s -> $textfile_dir/nvidia_gpu.prom)"
