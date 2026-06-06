#!/bin/sh
# Canonical OS / package-manager / system-tier detection.
# Source this from install.sh, install-packages.sh, and ~/.config/shell/init.sh.
# Sets and exports:
#   DOTFILES_OS           darwin | linux | wsl | unknown
#   DOTFILES_PKG          apt | pacman | brew | (empty if none)
#   DOTFILES_SYSTEM_TYPE  desktop | server | (empty)
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

DOTFILES_PKG=
case "$DOTFILES_OS" in
  darwin)
    command -v brew >/dev/null 2>&1 && DOTFILES_PKG=brew ;;
  linux|wsl)
    if   command -v apt    >/dev/null 2>&1; then DOTFILES_PKG=apt
    elif command -v pacman >/dev/null 2>&1; then DOTFILES_PKG=pacman
    fi ;;
esac
export DOTFILES_PKG

# Distro ID from /etc/os-release (e.g. ubuntu, debian, arch).
# DOTFILES_OS_RELEASE_FILE overrides the path, for testing.
_dotfiles_os_release="${DOTFILES_OS_RELEASE_FILE:-/etc/os-release}"
DOTFILES_DISTRO=
if [ -f "$_dotfiles_os_release" ]; then
  DOTFILES_DISTRO=$(. "$_dotfiles_os_release" 2>/dev/null && printf '%s' "${ID:-}")
fi
export DOTFILES_DISTRO
unset _dotfiles_os_release

_dotfiles_tier_file="${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles/system-type"
DOTFILES_SYSTEM_TYPE=
if [ -r "$_dotfiles_tier_file" ]; then
  DOTFILES_SYSTEM_TYPE=$(tr -d '[:space:]' < "$_dotfiles_tier_file" 2>/dev/null || printf '')
fi
case "$DOTFILES_SYSTEM_TYPE" in
  desktop|server) ;;
  *) DOTFILES_SYSTEM_TYPE= ;;
esac
export DOTFILES_SYSTEM_TYPE
unset _dotfiles_tier_file
