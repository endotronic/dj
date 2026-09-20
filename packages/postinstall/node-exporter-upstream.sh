#!/bin/sh
# Debian/Ubuntu's prometheus-node-exporter can sit many minor releases
# behind for the life of a stable release -- jammy ships 1.3.1. On
# Tegra (Jetson) that's not merely stale, it's fatal: thermal zones
# whose temp returns EAGAIN (cv0/cv1/cv2-thermal on Orin) make 1.3.1's
# thermal_zone collector block forever, so /metrics never responds at
# all and the scrape times out. Upstream handles EAGAIN by skipping
# the zone.
#
# So: keep the distro packages -- prometheus-node-exporter owns the
# unit, the `prometheus` user and /var/lib/prometheus/node-exporter,
# and prometheus-node-exporter-collectors owns the nvme/smartmon
# timers that generate the SMART .prom files -- but run the upstream
# binary via a drop-in that overrides ExecStart.
#
# The drop-in also passes --collector.textfile.directory explicitly:
# that default is a Debian patch, not an upstream one, so the upstream
# binary would otherwise read no textfile metrics and silently drop
# every nvme_*/smartmon_* series.
#
# DOTFILES_NE_* exist for tests; a real run never needs to set any.
set -eu

min_version="${DOTFILES_NE_MIN_VERSION:-1.9.0}"
packaged_bin="${DOTFILES_NE_PACKAGED_BIN:-/usr/bin/prometheus-node-exporter}"
bin_dir="${DOTFILES_NE_BIN_DIR:-/usr/local/bin}"
dropin_dir="${DOTFILES_NE_DROPIN_DIR:-/etc/systemd/system/prometheus-node-exporter.service.d}"
textfile_dir="${DOTFILES_NE_TEXTFILE_DIR:-/var/lib/prometheus/node-exporter}"
unit="${DOTFILES_NE_UNIT:-prometheus-node-exporter.service}"
target_bin="$bin_dir/node_exporter"

log() { printf '[postinstall:node-exporter-upstream] %s\n' "$1"; }

command -v systemctl >/dev/null 2>&1 || { log 'no systemd; skipping'; exit 0; }
[ -x "$packaged_bin" ] || { log "no $packaged_bin; skipping"; exit 0; }

# "node_exporter, version 1.3.1 (branch: ...)" -> 1.3.1
ne_version() {
  [ -x "$1" ] || return 1
  "$1" --version 2>&1 | awk '/version/ { for (i=1;i<=NF;i++) if ($i=="version") { print $(i+1); exit } }'
}

# True when $1 >= $2.
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]
}

packaged_version=$(ne_version "$packaged_bin" || true)
if [ -n "$packaged_version" ] && version_ge "$packaged_version" "$min_version"; then
  log "packaged node_exporter $packaged_version already >= $min_version; nothing to override"
  exit 0
fi

# Install the upstream binary unless a new-enough one is already there.
current=$(ne_version "$target_bin" 2>/dev/null || true)
if [ -n "$current" ] && version_ge "$current" "$min_version"; then
  log "$target_bin already at $current; skipping download"
else
  case "$(uname -m)" in
    x86_64)        ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7l)        ARCH=armv7 ;;
    *) log "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac

  # Resolve the latest release tag via the redirect URL, as
  # packages/scripts/sops.sh does.
  version="${DOTFILES_NE_VERSION:-}"
  if [ -z "$version" ]; then
    version=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
      'https://github.com/prometheus/node_exporter/releases/latest' \
      | sed 's|.*releases/tag/v||')
  fi
  [ -n "$version" ] || { log 'could not resolve latest node_exporter version' >&2; exit 1; }

  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  tarball="node_exporter-${version}.linux-${ARCH}.tar.gz"
  log "installing upstream v${version} (${ARCH}), replacing packaged ${packaged_version:-unknown}"
  curl -fsSL -o "$TMP/$tarball" \
    "https://github.com/prometheus/node_exporter/releases/download/v${version}/${tarball}"
  tar -xzf "$TMP/$tarball" -C "$TMP"
  sudo install -m 0755 "$TMP/node_exporter-${version}.linux-${ARCH}/node_exporter" "$target_bin"
fi

# Override ExecStart to run the upstream binary. ExecStart= on its own
# line clears the unit's own value first -- without that, systemd
# rejects a second ExecStart on a Type=simple service.
dropin="$dropin_dir/10-upstream-binary.conf"
desired=$(cat <<EOF
# Managed by dotfiles (packages/postinstall/node-exporter-upstream.sh).
[Service]
ExecStart=
ExecStart=$target_bin --collector.textfile.directory=$textfile_dir \$ARGS
EOF
)

if [ "$(cat "$dropin" 2>/dev/null || true)" = "$desired" ]; then
  log 'drop-in already current'
else
  sudo mkdir -p "$dropin_dir"
  printf '%s\n' "$desired" | sudo tee "$dropin" >/dev/null
  log "wrote $dropin"
  sudo systemctl daemon-reload
fi

sudo systemctl enable "$unit" >/dev/null 2>&1 || true
sudo systemctl restart "$unit"
log "restarted $unit -- $(ne_version "$target_bin" || echo '?') now serving on :9100"
