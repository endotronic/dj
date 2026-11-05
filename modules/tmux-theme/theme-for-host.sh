#!/bin/sh
# Print a 6-digit hex accent color for a host name, for `dj setup`'s
# --theme when you didn't pass one.
#
# Usage: theme-for-host.sh NAME
#
# First choice is claude, best-effort and bounded: `claude -p` with a
# 20 s timeout, asked for a color evocative of NAME. Any failure (no
# claude, no `timeout` to bound it, no hex in the reply, a timeout) falls
# through to a random color, so every machine still gets a distinct one
# instead of all sharing the default. Always prints a color; logs which
# tier produced it on stderr.

set -eu

name=${1:?usage: theme-for-host.sh NAME}
log() { printf '[dj-setup] %s\n' "$*" >&2; }

color=
# GNU timeout; Homebrew's coreutils installs it as gtimeout on macOS.
to=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
if command -v claude >/dev/null 2>&1 && [ -n "$to" ]; then
  prompt="Respond with ONLY a 6-digit hex color code (like #2596be) and nothing else -- no explanation, no markdown -- that you associate with or that is evocative of the word \"$name\" (for example, what a similar-sounding color name suggests). If nothing specific comes to mind, pick any pleasant accent color."
  color=$("$to" 20 claude -p "$prompt" 2>/dev/null | grep -oE '#[0-9a-fA-F]{6}' | head -n1) || color=
fi
if [ -n "$color" ]; then
  log "generated tmux theme color for $name via claude: $color"
else
  hex=$(od -An -N3 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  if [ -z "$hex" ]; then
    # /dev/urandom unreadable: awk's rand(), seeded from pid + time.
    hex=$(awk -v seed="$$$(date +%s)" 'BEGIN { srand(seed); printf "%06x", int(rand() * 16777216) }')
  fi
  color="#$hex"
  log "no theme from claude; generated a random one for $name: $color"
fi
printf '%s\n' "$color"
