#!/bin/sh
# Not a postinstall hook itself -- the payload script that the
# zfs-textfile-collector hook (same directory) deploys to
# /usr/local/bin and runs on a timer. Kept as its own file (rather
# than embedded in the hook as a heredoc) so it's directly testable
# and so `zpool status` parsing has one home.
#
# Collects ZFS vdev-level READ/WRITE/CKSUM error counts and scrub
# status into a node_exporter textfile-collector .prom file.
# node_exporter's own built-in zfs collector only exposes
# kstat-derived stats (ARC, ABD, ...) plus overall pool state
# (node_zfs_zpool_state) -- it has no visibility into per-vdev I/O
# error counters or scrub history, both of which only ever appear in
# `zpool status` text output (OpenZFS 2.2.7 on this fleet predates
# `zpool status --json`). This fills that gap the same way the
# existing smartmon/nvme textfile collectors (from
# prometheus-node-exporter-collectors) fill the SMART/NVMe gap.
#
# A drive can accumulate nonzero READ/WRITE/CKSUM counts on an
# otherwise-ONLINE pool well before ZFS marks it DEGRADED -- that's
# the whole point of tracking these separately from
# node_zfs_zpool_state.
#
# `zpool status` only ever reports the single most recent scan event,
# with no memory of whether an earlier one actually finished -- a
# canceled or in-progress scrub gives no way to tell, from that one
# invocation, when a scrub last actually completed. To answer "how
# long since the last scrub actually finished" (as opposed to "when
# was the most recent scan attempt, whatever its outcome"), this
# script keeps a tiny local cache under
# $ZFS_SCRUB_STATE_DIR/<pool>.last_scrub, updated only when a scan
# reports "scrub repaired ... with N errors on <date>", and always
# re-emitted regardless of what the *current* scan line says -- so a
# later canceled or in-progress scrub doesn't make the last known-good
# completion disappear from Prometheus.
set -eu

textfile_dir="${DOTFILES_TEXTFILE_COLLECTOR_DIR:-/var/lib/prometheus/node-exporter}"
state_dir="${DOTFILES_ZFS_SCRUB_STATE_DIR:-/var/lib/zfs-vdev-textfile-collector}"
out="$textfile_dir/zfs_vdev.prom"

command -v zpool >/dev/null 2>&1 || { printf '[zfs-vdev-textfile-collector] zpool not found; skipping\n' >&2; exit 0; }

mkdir -p "$state_dir"
tmp=$(mktemp "$textfile_dir/.zfs_vdev.prom.XXXXXX")
trap 'rm -f "$tmp"' EXIT INT TERM

{
  printf '# HELP zfs_vdev_read_errors Cumulative READ error count reported by zpool status for this vdev.\n'
  printf '# TYPE zfs_vdev_read_errors gauge\n'
  printf '# HELP zfs_vdev_write_errors Cumulative WRITE error count reported by zpool status for this vdev.\n'
  printf '# TYPE zfs_vdev_write_errors gauge\n'
  printf '# HELP zfs_vdev_cksum_errors Cumulative CKSUM error count reported by zpool status for this vdev.\n'
  printf '# TYPE zfs_vdev_cksum_errors gauge\n'
  printf '# HELP zfs_scrub_state Current zpool scan state: 0=none 1=scanning 2=finished 3=canceled 4=resilvering.\n'
  printf '# TYPE zfs_scrub_state gauge\n'
  printf '# HELP zfs_last_scrub_completed_seconds Unix timestamp of the last scrub that actually finished (not canceled/in-progress).\n'
  printf '# TYPE zfs_last_scrub_completed_seconds gauge\n'
  printf '# HELP zfs_last_scrub_errors Error count reported by the last scrub that actually finished.\n'
  printf '# TYPE zfs_last_scrub_errors gauge\n'

  for pool in $(zpool list -H -o name 2>/dev/null); do
    esc_pool=$(printf '%s' "$pool" | sed 's/\\/\\\\/g; s/"/\\"/g')

    # --- per-vdev READ/WRITE/CKSUM, from the config table -----------
    # Only lines whose last 3 fields are all plain digits qualify --
    # a trailing annotation like "(resilvering)" adds a 6th field and
    # pushes $NF off the CKSUM column, so such a line is safely
    # skipped rather than misparsed.
    zpool status -P "$pool" 2>/dev/null | awk -v pool="$esc_pool" '
      BEGIN { in_config = 0 }
      /^config:/ { in_config = 1; next }
      /^errors:/ { in_config = 0 }
      in_config && NF >= 5 && $1 != "NAME" {
        vdev = $1
        gsub(/\\/, "\\\\", vdev); gsub(/"/, "\\\"", vdev)
        read = $(NF-2); write = $(NF-1); cksum = $NF
        if (read ~ /^[0-9]+$/ && write ~ /^[0-9]+$/ && cksum ~ /^[0-9]+$/) {
          printf "zfs_vdev_read_errors{zpool=\"%s\",vdev=\"%s\"} %s\n", pool, vdev, read
          printf "zfs_vdev_write_errors{zpool=\"%s\",vdev=\"%s\"} %s\n", pool, vdev, write
          printf "zfs_vdev_cksum_errors{zpool=\"%s\",vdev=\"%s\"} %s\n", pool, vdev, cksum
        }
      }
    '

    # --- scan/scrub state, from the plain (non -P) status text ------
    scan_line=$(zpool status "$pool" 2>/dev/null | awk '/^[[:space:]]*scan:/{ $1=""; sub(/^ /,""); print; exit }')

    state=0
    case "$scan_line" in
      *'scrub in progress'*) state=1 ;;
      *'scrub repaired'*)    state=2 ;;
      *'scrub canceled'*)    state=3 ;;
      *resilver*)            state=4 ;;
    esac
    printf 'zfs_scrub_state{zpool="%s"} %s\n' "$esc_pool" "$state"

    state_file="$state_dir/$pool.last_scrub"
    case "$scan_line" in
      *'scrub repaired'*'with '*' errors on '*)
        errors=$(printf '%s\n' "$scan_line" | sed -n 's/.*with \([0-9][0-9]*\) errors on .*/\1/p')
        date_part=$(printf '%s\n' "$scan_line" | sed -n 's/.* errors on \(.*\)$/\1/p')
        epoch=$(date -d "$date_part" +%s 2>/dev/null || true)
        if [ -n "$epoch" ] && [ -n "$errors" ]; then
          printf '%s %s\n' "$epoch" "$errors" > "$state_file"
        fi
        ;;
    esac
    if [ -f "$state_file" ]; then
      cached_epoch=
      cached_errors=
      read -r cached_epoch cached_errors < "$state_file"
      case "$cached_epoch" in
        *[!0-9]*|'') ;;
        *)
          printf 'zfs_last_scrub_completed_seconds{zpool="%s"} %s\n' "$esc_pool" "$cached_epoch"
          printf 'zfs_last_scrub_errors{zpool="%s"} %s\n' "$esc_pool" "$cached_errors"
          ;;
      esac
    fi
  done
} > "$tmp"

chmod 644 "$tmp"
mv "$tmp" "$out"
