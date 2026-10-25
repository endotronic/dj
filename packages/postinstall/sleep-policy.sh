#!/bin/sh
# Laptop sleep policy: suspend when idle, hibernate an hour in, and
# hibernate whenever the battery is nearly flat -- awake or asleep.
#
#   idle 10m   hypridle runs `systemctl suspend-then-hibernate` (the
#              listener lives in ~/.config/hypr/hypridle.conf, private
#              repo; this hook only enables the service that runs it)
#   +50m       systemd wakes on an RTC alarm and hibernates, i.e. 1h
#              after the machine went idle. HibernateDelaySec below.
#   <=5%       asleep: systemd's suspend-then-hibernate battery alarm
#              wakes it to hibernate "whichever comes first" with the
#              delay. Awake: UPower hibernates at PercentageAction.
#   lid close  suspend-then-hibernate too (same 50m delay from close)
#
# Everything here is a drop-in under /etc (systemd sleep, logind, UPower);
# nothing shipped by a package is edited. Plain `systemctl suspend` (e.g.
# a menu entry) is NOT covered by the asleep-at-5% rule -- only
# suspend-then-hibernate sets the alarm.
#
# N/A (exits 0, changes nothing) without a battery, or without hibernation
# configured (no resume= on the kernel command line): suspend-then-hibernate
# would otherwise promise a hibernate that can't resume.
#
# DOTFILES_SLEEP_ETC / DOTFILES_POWER_SUPPLY_DIR / DOTFILES_CMDLINE_FILE
# exist for tests; a real run never needs to set them.
set -eu

tag='postinstall:sleep-policy'
ETC="${DOTFILES_SLEEP_ETC:-/etc}"
POWER_SUPPLY="${DOTFILES_POWER_SUPPLY_DIR:-/sys/class/power_supply}"
CMDLINE="${DOTFILES_CMDLINE_FILE:-/proc/cmdline}"

log() { printf '[%s] %s\n' "$tag" "$*" >&2; }

[ "$(uname -s)" = Linux ] || { log 'not Linux; skipping'; exit 0; }
command -v systemctl >/dev/null 2>&1 || { log 'no systemd; skipping'; exit 0; }

_bat=
for _b in "$POWER_SUPPLY"/BAT*; do [ -e "$_b" ] && _bat=1; done
[ -n "$_bat" ] || { log 'no battery; skipping'; exit 0; }

grep -q 'resume=' "$CMDLINE" 2>/dev/null || {
  log 'hibernation not configured (no resume= on the kernel command line); skipping'
  log 'run `omarchy-hibernation-setup` (Omarchy) or set up a resume swap first'
  exit 0
}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT INT TERM

# put <dest> -- install stdin to <dest> (0644, root) if its content differs.
# Prints "changed" on stdout when it wrote.
put() {
  cat > "$tmp"
  if [ -f "$1" ] && cmp -s "$tmp" "$1"; then return 0; fi
  sudo mkdir -p "$(dirname "$1")"
  sudo install -m 0644 "$tmp" "$1"
  log "wrote $1"
  printf changed
}

# systemd-sleep reads sleep.conf.d on every sleep; no reload needed.
put "$ETC/systemd/sleep.conf.d/10-hibernate-delay.conf" >/dev/null <<'EOF'
[Sleep]
# 10m idle (hypridle) + 50m = hibernate 1h after going idle.
HibernateDelaySec=50min
EOF

logind_changed=$(put "$ETC/systemd/logind.conf.d/30-lid-suspend-then-hibernate.conf" <<'EOF'
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchExternalPower=suspend-then-hibernate
EOF
)

upower_changed=$(put "$ETC/UPower/UPower.conf.d/10-hibernate-at-5.conf" <<'EOF'
[UPower]
# Hibernate (not UPower's default HybridSleep) at 5% while awake.
# Low > Critical > Action is required.
PercentageLow=20
PercentageCritical=10
PercentageAction=5
CriticalPowerAction=Hibernate
EOF
)

# logind rereads its config on SIGHUP; restarting it would drop the seat.
[ -z "$logind_changed" ] || sudo systemctl kill -s HUP systemd-logind.service
[ -z "$upower_changed" ] || sudo systemctl restart upower.service

# The idle half: hypridle's own user unit, if the package is installed.
if command -v hypridle >/dev/null 2>&1; then
  if systemctl --user cat hypridle.service >/dev/null 2>&1; then
    systemctl --user enable hypridle.service >/dev/null 2>&1 || log 'could not enable hypridle.service'
    systemctl --user start hypridle.service >/dev/null 2>&1 \
      || log 'hypridle.service did not start now (no graphical session?); it will on next login'
  else
    log 'hypridle installed but ships no user unit; start it from your compositor autostart'
  fi
else
  log 'hypridle not installed; no idle->suspend trigger (add it to this host'"'"'s package list)'
fi

log 'done'
