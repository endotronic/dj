#!/bin/sh
# Canonical OS / package-manager / system-tier detection.
# Source this from install.sh, install-packages.sh, and ~/.config/shell/init.sh.
# Sets and exports:
#   DOTFILES_OS           darwin | linux | wsl | unknown
#   DOTFILES_PKG          apt | pacman | brew | nix | (empty if none)
#   DOTFILES_SYSTEM_TYPE  any identifier (letters, digits, _, -) | (empty)
# Safe to source repeatedly; idempotent.

case "$(uname -s)" in
  Darwin) DOTFILES_OS=darwin ;;
  Linux)
    if [ -r /proc/version ] && grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
      DOTFILES_OS=wsl
    else
      DOTFILES_OS=linux
    fi ;;
  *) DOTFILES_OS=unknown ;;
esac
export DOTFILES_OS

# Distro ID from /etc/os-release (e.g. ubuntu, debian, arch).
# DOTFILES_OS_RELEASE_FILE overrides the path, for testing.
_dotfiles_os_release="${DOTFILES_OS_RELEASE_FILE:-/etc/os-release}"
DOTFILES_DISTRO=
if [ -f "$_dotfiles_os_release" ]; then
  DOTFILES_DISTRO=$(. "$_dotfiles_os_release" 2>/dev/null && printf '%s' "${ID:-}")
fi
export DOTFILES_DISTRO
unset _dotfiles_os_release

DOTFILES_PKG=
case "$DOTFILES_OS" in
  darwin)
    command -v brew >/dev/null 2>&1 && DOTFILES_PKG=brew ;;
  linux|wsl)
    # NixOS is recognized by its os-release ID, not by `nix` on PATH:
    # Nix also installs on top of Debian or Arch, where the distro's own
    # manager stays the one dj uses.
    if   [ "$DOTFILES_DISTRO" = nixos ] && command -v nix >/dev/null 2>&1; then DOTFILES_PKG=nix
    elif command -v apt    >/dev/null 2>&1; then DOTFILES_PKG=apt
    elif command -v pacman >/dev/null 2>&1; then DOTFILES_PKG=pacman
    fi ;;
esac
export DOTFILES_PKG

_dotfiles_tier_file="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/system-type"
DOTFILES_SYSTEM_TYPE=
if [ -r "$_dotfiles_tier_file" ]; then
  DOTFILES_SYSTEM_TYPE=$(tr -d '[:space:]' < "$_dotfiles_tier_file" 2>/dev/null || printf '')
fi
case "$DOTFILES_SYSTEM_TYPE" in
  ''|*[!A-Za-z0-9_-]*) DOTFILES_SYSTEM_TYPE= ;;
esac
export DOTFILES_SYSTEM_TYPE
unset _dotfiles_tier_file
