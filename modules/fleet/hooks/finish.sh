#!/bin/sh
# fleet module, at the end of install.sh: offer to register this machine
# in ~/.ssh/config so your other machines can reach it by name. Grouped
# under this machine's own system type (persisted earlier in install.sh).
# Interactive only; ssh-menu-register.sh does nothing without a terminal.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ -d "${DOT_DIR:-$HOME/.config.git}" ] || exit 0
sh "$here/ssh-menu-register.sh"
