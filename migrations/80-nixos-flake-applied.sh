#!/bin/sh
# Migration: nixos-flake-applied
#
# On NixOS the system is whatever ~/.config/nixos (private repo, travels
# with `dj sync`) builds for this hostname. A pull that changes it leaves
# the machine running the old generation until someone runs
# nixos-rebuild, and nothing complains. The check evaluates the flake
# (no build) and compares its system path with /run/current-system, so
# it's a predicate on live state, not a stamp. Auto-fixable: local, and
# the previous generation stays one `nixos-rebuild switch --rollback`
# (or a boot-menu entry) away.
#
# `path:` keeps Nix from looking for a .git above the directory: the
# flake is exactly that directory, nothing else in $HOME.

. "${DJ_MIGRATION_LIB:?run via scripts/migrate.sh}"

desc() { echo "the running NixOS system is what ~/.config/nixos builds for this host"; }

nixos_flake_dir() { printf '%s' "${DOTFILES_NIXOS_FLAKE:-$HOME/.config/nixos}"; }
nixos_host() { hostname -s 2>/dev/null || uname -n; }
nixos_nix() { nix --extra-experimental-features 'nix-command flakes' "$@"; }

check() {
  on_nixos || return 2
  command -v nix >/dev/null 2>&1 || return 2
  _fd=$(nixos_flake_dir)
  [ -f "$_fd/flake.nix" ] || return 2
  _host=$(nixos_host)
  # A host the flake doesn't describe is managed some other way.
  nixos_nix eval --no-write-lock-file --json "path:$_fd#nixosConfigurations" \
      --apply builtins.attrNames 2>/dev/null | tr -d '[]"' | tr ',' '\n' \
    | grep -Fxq -- "$_host" || return 2
  # An evaluation error is pending too: the fix shows the error.
  _want=$(nixos_nix eval --no-write-lock-file --raw \
    "path:$_fd#nixosConfigurations.$_host.config.system.build.toplevel.outPath" \
    2>/dev/null) || return 1
  _have=$(readlink -f "${DOTFILES_CURRENT_SYSTEM:-/run/current-system}" 2>/dev/null || true)
  [ -n "$_want" ] && [ "$_want" = "$_have" ]
}

fix() {
  _fd=$(nixos_flake_dir)
  _host=$(nixos_host)
  log "nixos-rebuild switch --flake path:$_fd#$_host"
  sudo nixos-rebuild switch --flake "path:$_fd#$_host"
}

migration_main "$@"
