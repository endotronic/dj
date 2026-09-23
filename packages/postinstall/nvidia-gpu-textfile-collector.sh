#!/bin/sh
# Not a postinstall hook itself -- the payload script that the
# nvidia-textfile-collector hook (same directory) deploys to
# /usr/local/bin and runs as a service. Kept as its own file so it's
# directly testable and so nvidia-smi parsing has one home.
#
# Writes GPU metrics from `nvidia-smi --query-gpu` (power draw,
# temperature, utilization, clocks, ...) and per-process GPU memory
# from `--query-compute-apps` into a node_exporter textfile-collector
# .prom file, so the node_exporter Prometheus already scrapes carries
# them -- no second exporter, port, or scrape job.
#
# Chosen over dcgm-exporter because that needs DCGM (not packaged for
# every host, and heavy for "what's the power draw"), and because on a
# unified-memory GPU (GB10 / DGX Spark) most of what DCGM adds is N/A
# anyway. Fields nvidia-smi reports as N/A / [N/A] / "Not Supported"
# are simply omitted, so the same script works on a discrete card
# (where memory.used/total etc. do have values) and on GB10 (where
# they don't -- node_exporter's own meminfo covers the shared pool).
#
# Runs once by default; `--interval N` loops every N seconds (what
# the systemd service uses -- a long-running loop rather than a 15s
# timer, which would log two journal lines per run forever).
set -eu

textfile_dir="${DOTFILES_TEXTFILE_COLLECTOR_DIR:-/var/lib/prometheus/node-exporter}"
out="$textfile_dir/nvidia_gpu.prom"

interval=
case "${1:-}" in
  --interval) interval="${2:?--interval needs a value}" ;;
  '') ;;
  *) printf 'usage: %s [--interval SECONDS]\n' "$0" >&2; exit 2 ;;
esac

command -v nvidia-smi >/dev/null 2>&1 || { printf '[nvidia-gpu-textfile-collector] nvidia-smi not found; skipping\n' >&2; exit 0; }

gpu_fields='index,uuid,name,driver_version,pstate,temperature.gpu,temperature.memory,power.draw,power.draw.instant,enforced.power.limit,utilization.gpu,utilization.memory,memory.used,memory.total,clocks.gr,clocks.sm,clocks.mem,clocks.video,clocks.max.gr,clocks.max.mem,fan.speed,clocks_event_reasons.active'

collect() {
  # --- per-GPU ------------------------------------------------------
  # Both queries feed one awk program, separated by a marker line:
  # a metric family's samples must be contiguous in the exposition
  # format, so everything is buffered per metric and printed grouped
  # at the end rather than GPU-by-GPU.
  # A failing nvidia-smi (driver/NVML mismatch after an upgrade, say)
  # prints its error on stdout; drop that rather than parse it as a GPU.
  gpu_rc=0
  gpu_csv=$(nvidia-smi --query-gpu="$gpu_fields" --format=csv,noheader,nounits 2>/dev/null) || gpu_rc=$?
  [ "$gpu_rc" -eq 0 ] || gpu_csv=
  {
    [ -z "$gpu_csv" ] || printf '%s\n' "$gpu_csv"
    echo '@@apps'
    # Keyed by gpu_uuid (not index); an empty result is normal.
    nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null || true
    echo "@@rc $gpu_rc"
  } | awk -F', ' '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\n/, "\\n", s); return s }
    function na(v) { return v == "" || v ~ /N\/A|Not Supported|Unknown|Insufficient|Error/ }
    function add(name, help, labels, v, scale) {
      if (na(v)) return
      if (!(name in seen)) { seen[name] = 1; order[++n] = name; helps[name] = help }
      body[name] = body[name] sprintf("%s{%s} %.15g\n", name, labels, v * scale)
    }
    $0 == "@@apps" { apps = 1; next }
    /^@@rc / { split($0, a, " "); rc = a[2]; next }
    !apps {
      idx = $1; uuid = esc($2); gname = esc($3); drv = esc($4)
      l = sprintf("gpu=\"%s\",uuid=\"%s\"", idx, uuid)
      add("nvidia_gpu_info", "Constant 1, labelled with the GPU name and driver version.", \
          sprintf("%s,name=\"%s\",driver_version=\"%s\"", l, gname, drv), 1, 1)
      p = $5; sub(/^P/, "", p)
      add("nvidia_gpu_pstate", "Performance state (0 = max performance, 15 = min).", l, p, 1)
      add("nvidia_gpu_temperature_celsius", "GPU core temperature.", l, $6, 1)
      add("nvidia_gpu_memory_temperature_celsius", "GPU memory temperature.", l, $7, 1)
      add("nvidia_gpu_power_draw_watts", "Power draw averaged over the last second (nvidia-smi power.draw).", l, $8, 1)
      add("nvidia_gpu_power_draw_instant_watts", "Instantaneous power draw (nvidia-smi power.draw.instant).", l, $9, 1)
      add("nvidia_gpu_power_limit_watts", "Enforced power limit.", l, $10, 1)
      add("nvidia_gpu_utilization_ratio", "Fraction of the last sample period a kernel was running.", l, $11, 0.01)
      add("nvidia_gpu_memory_utilization_ratio", "Fraction of the last sample period memory was being read or written.", l, $12, 0.01)
      add("nvidia_gpu_memory_used_bytes", "Framebuffer memory in use.", l, $13, 1048576)
      add("nvidia_gpu_memory_total_bytes", "Total framebuffer memory.", l, $14, 1048576)
      add("nvidia_gpu_clock_hz", "Current clock frequency.", l ",clock=\"graphics\"", $15, 1e6)
      add("nvidia_gpu_clock_hz", "", l ",clock=\"sm\"", $16, 1e6)
      add("nvidia_gpu_clock_hz", "", l ",clock=\"memory\"", $17, 1e6)
      add("nvidia_gpu_clock_hz", "", l ",clock=\"video\"", $18, 1e6)
      add("nvidia_gpu_clock_max_hz", "Maximum clock frequency.", l ",clock=\"graphics\"", $19, 1e6)
      add("nvidia_gpu_clock_max_hz", "", l ",clock=\"memory\"", $20, 1e6)
      add("nvidia_gpu_fan_speed_ratio", "Fan speed as a fraction of maximum.", l, $21, 0.01)
      r = $22
      if (!na(r) && r ~ /^0x/) {
        # Hex bitmask of why clocks are held down (nvmlClocksEventReasons);
        # 0 = not throttled. strtonum is gawk-only, so decode by hand.
        r = tolower(substr(r, 3)); v = 0
        for (i = 1; i <= length(r); i++) v = v * 16 + index("0123456789abcdef", substr(r, i, 1)) - 1
        add("nvidia_gpu_clocks_event_reasons", "Bitmask of active clock event (throttle) reasons; 0 = none.", l, v, 1)
      }
      next
    }
    NF >= 4 {
      add("nvidia_gpu_process_memory_used_bytes", "GPU memory used by a compute process.", \
          sprintf("uuid=\"%s\",pid=\"%s\",process_name=\"%s\"", esc($1), $2, esc($3)), $4, 1048576)
    }
    END {
      for (i = 1; i <= n; i++) {
        m = order[i]
        printf "# HELP %s %s\n# TYPE %s gauge\n%s", m, helps[m], m, body[m]
      }
      print "# HELP nvidia_gpu_collector_success 1 if the last nvidia-smi query succeeded."
      print "# TYPE nvidia_gpu_collector_success gauge"
      printf "nvidia_gpu_collector_success %d\n", (rc == 0)
    }
  '
}

write_once() {
  tmp=$(mktemp "$textfile_dir/.nvidia_gpu.prom.XXXXXX")
  trap 'rm -f "$tmp"' EXIT INT TERM
  collect > "$tmp"
  chmod 644 "$tmp"
  mv "$tmp" "$out"
  trap - EXIT INT TERM
}

if [ -z "$interval" ]; then
  write_once
  exit 0
fi

while :; do
  write_once
  sleep "$interval"
done
