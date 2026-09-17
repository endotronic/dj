#!/bin/sh
# tmux.conf's clickable status-bar buttons (NEW / <-- / --> -- see the
# range=user styles in tmux.conf's status-left/-right and the
# generated dispatcher in scripts/gen-ssh-menu.sh) depend on the
# range=user style and the #{mouse_status_range} format, both added in
# tmux 3.4. Debian's own repo can sit below that for the life of a
# whole stable release -- bookworm ships 3.3a with nothing newer in
# main -- so on Debian only, once the installed tmux is too old, pull
# it from <codename>-backports instead. No-op everywhere else: Arch
# and brew already track current releases, and Ubuntu's
# backports pocket/mirror setup differs enough that guessing at it
# here isn't worth it.
#
# DOTFILES_OS_RELEASE_FILE, DOTFILES_APT_SOURCES_DIR and
# DOTFILES_TMUX_MIN_VERSION exist for tests; a real run never needs to
# set any of them.
set -eu

min_version="${DOTFILES_TMUX_MIN_VERSION:-3.4}"
os_release="${DOTFILES_OS_RELEASE_FILE:-/etc/os-release}"
sources_dir="${DOTFILES_APT_SOURCES_DIR:-/etc/apt/sources.list.d}"

command -v dpkg    >/dev/null 2>&1 || { printf '[postinstall:tmux-backports] not a dpkg system; skipping\n'; exit 0; }
command -v apt-get >/dev/null 2>&1 || { printf '[postinstall:tmux-backports] apt-get not found; skipping\n'; exit 0; }

ID=
VERSION_CODENAME=
[ -f "$os_release" ] && . "$os_release" 2>/dev/null || true

if [ "${ID:-}" != debian ]; then
  printf '[postinstall:tmux-backports] not Debian (ID=%s); skipping\n' "${ID:-unknown}"
  exit 0
fi

if ! dpkg -s tmux >/dev/null 2>&1; then
  printf '[postinstall:tmux-backports] tmux not installed; skipping\n'
  exit 0
fi

installed=$(dpkg-query -W -f='${Version}' tmux)
if dpkg --compare-versions "$installed" ge "$min_version"; then
  printf '[postinstall:tmux-backports] tmux %s already >= %s; skipping\n' "$installed" "$min_version"
  exit 0
fi

if [ -z "${VERSION_CODENAME:-}" ]; then
  printf '[postinstall:tmux-backports] could not determine VERSION_CODENAME; skipping\n' >&2
  exit 1
fi

list_file="$sources_dir/${VERSION_CODENAME}-backports.list"
line="deb http://deb.debian.org/debian ${VERSION_CODENAME}-backports main"

if ! grep -qxF "$line" "$list_file" 2>/dev/null; then
  printf '%s\n' "$line" | sudo tee "$list_file" >/dev/null
fi

# Tolerated like every other apt-get update call in this project: a
# repo unrelated to backports (e.g. Proxmox's paywalled enterprise
# repo) can 401 and make apt-get update exit non-zero even though the
# index we actually need refreshed fine.
sudo apt-get update || true
sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
  apt-get install -y -t "${VERSION_CODENAME}-backports" tmux

new_version=$(dpkg-query -W -f='${Version}' tmux)
if dpkg --compare-versions "$new_version" ge "$min_version"; then
  printf '[postinstall:tmux-backports] upgraded tmux %s -> %s -- restart the tmux server (kill-server, then reattach) to pick it up\n' \
    "$installed" "$new_version"
else
  printf '[postinstall:tmux-backports] WARNING: tmux still %s after installing from %s-backports\n' \
    "$new_version" "$VERSION_CODENAME" >&2
  exit 1
fi
