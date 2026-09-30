#!/bin/sh
# Not a postinstall hook itself -- the payload script that the
# memory-textfile-collector hook (same directory) deploys to
# /usr/local/bin and runs on a timer. Kept as its own file so it's
# directly testable.
#
# Writes the host's *physical* memory size into a node_exporter
# textfile-collector .prom file. node_exporter has no such metric on
# Linux: every node_memory_* comes from /proc/meminfo, whose MemTotal
# is only what the kernel can allocate -- firmware carve-outs, the
# kernel image and the struct page array are already gone by then
# (~6 GiB of 128 on a GB10). Two concrete sources, both exported so a
# dashboard can prefer one and fall back to the other:
#
#   host_memory_online_bytes     online memory blocks in
#                                /sys/devices/system/memory x block
#                                size -- the physical RAM the kernel
#                                was handed (same figure as `lsmem`).
#                                No root needed; absent in some
#                                containers/VMs without memory hotplug.
#   host_memory_installed_bytes  sum of SMBIOS type 17 (Memory Device)
#                                sizes via dmidecode -- what's actually
#                                installed. Needs root; omitted when
#                                dmidecode is missing, fails, or reports
#                                no modules (common on VMs).
#
# "Reserved" on a dashboard is then installed (or online) - MemTotal.
set -eu

textfile_dir="${DOTFILES_TEXTFILE_COLLECTOR_DIR:-/var/lib/prometheus/node-exporter}"
sysfs_dir="${DOTFILES_SYSFS_MEMORY_DIR:-/sys/devices/system/memory}"
out="$textfile_dir/memory_size.prom"

online_bytes() {
  [ -r "$sysfs_dir/block_size_bytes" ] || return 0
  bs=$(cat "$sysfs_dir/block_size_bytes")
  n=0
  for s in "$sysfs_dir"/memory*/state; do
    [ -r "$s" ] || continue
    [ "$(cat "$s")" = online ] && n=$((n + 1))
  done
  [ "$n" -gt 0 ] || return 0
  # block_size_bytes is hex without a 0x prefix.
  printf '%s\n' $((0x$bs * n))
}

installed_bytes() {
  command -v dmidecode >/dev/null 2>&1 || return 0
  dmidecode --type 17 2>/dev/null | awk '
    # "Size: 16 GB" / "Size: 16384 MB" / "Size: No Module Installed".
    # Anchored on the leading tab so "Volatile Size:", "Cache Size:"
    # and friends do not match.
    /^\tSize: [0-9]/ {
      u = $3
      m = (u == "kB" || u == "KB") ? 1024 : u == "MB" ? 1048576 : u == "GB" ? 1073741824 : u == "TB" ? 1099511627776 : 0
      t += $2 * m
    }
    END { if (t > 0) printf "%.0f\n", t }
  ' || true
}

collect() {
  v=$(online_bytes)
  if [ -n "$v" ]; then
    echo '# HELP host_memory_online_bytes Physical memory in online memory blocks (/sys/devices/system/memory).'
    echo '# TYPE host_memory_online_bytes gauge'
    echo "host_memory_online_bytes $v"
  fi
  v=$(installed_bytes)
  if [ -n "$v" ]; then
    echo '# HELP host_memory_installed_bytes Installed physical memory per SMBIOS type 17 (dmidecode).'
    echo '# TYPE host_memory_installed_bytes gauge'
    echo "host_memory_installed_bytes $v"
  fi
}

tmp=$(mktemp "$textfile_dir/.memory_size.prom.XXXXXX")
trap 'rm -f "$tmp"' EXIT INT TERM
collect > "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$out"
trap - EXIT INT TERM
