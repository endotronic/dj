# Helpers for migration scripts. Each migration sources this (scripts/
# migrate.sh exports its path as DJ_MIGRATION_LIB), defines desc, check
# and fix, and ends with `migration_main "$@"`. See migrations/README.md.
#
# check exits 0 = already satisfied, 1 = pending, 2 = N/A on this machine.
# fix repairs (or, for a MANUAL migration, prints what to do by hand).

set -eu

DOT_DIR=${DOT_DIR:-$HOME/.config.git}
REPO_ROOT=${DOTFILES_REPO_ROOT:-${DJ_REPO_ROOT:-$HOME/.dotfiles}}

log() { printf '        %s\n' "$*"; }

dot() { git --git-dir="$DOT_DIR" --work-tree="$HOME" "$@"; }

# One backup directory per migrate.sh run, shared by every migration
# that displaces a file; created on first use.
backup_dir() {
  _bd=${DJ_MIGRATE_BACKUP:-${DOTFILES_BACKUP_DIR:-$HOME/.dotfiles-backup/$(date -u +%Y%m%dT%H%M%SZ)}}
  mkdir -p "$_bd"
  printf '%s' "$_bd"
}

# NixOS builds /etc, units, users and sudo rules from the system flake,
# so a migration whose repair would edit them is N/A there. Same
# os-release rule as scripts/os-detect.sh.
on_nixos() {
  _osr=${DOTFILES_OS_RELEASE_FILE:-/etc/os-release}
  [ -f "$_osr" ] || return 1
  [ "$(. "$_osr" 2>/dev/null; printf '%s' "${ID:-}")" = nixos ]
}

this_host() { hostname -s 2>/dev/null || uname -n; }

ssh_fp() {
  ssh-keygen -lf "$1" 2>/dev/null | awk '{print $2}'
}

migration_main() {
  case "${1:-}" in
    desc)  desc ;;
    check) _rc=0; check || _rc=$?; exit "$_rc" ;;
    fix)   _rc=0; fix || _rc=$?; exit "$_rc" ;;
    *)     printf 'usage: %s desc|check|fix\n' "$0" >&2; exit 2 ;;
  esac
}
