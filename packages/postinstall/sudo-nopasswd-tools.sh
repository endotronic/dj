#!/bin/sh
# Passwordless sudo for `wg show`, docker and zfs, via a /etc/sudoers.d
# drop-in scoped to the invoking user.
#
# `wg show` needs root even to read (the Omarchy bar's WireGuard widget
# wants the last-handshake time), and routine docker / zfs work is a
# stream of sudo prompts. The rule grants:
#
#   wg show *      read-only; no `wg set`, no `wg-quick`
#   docker, zfs    any arguments
#
# Only tools actually installed here are listed, so re-running after
# installing another one extends the rule.
#
# This is a bigger grant than it looks: docker access is already
# root-equivalent (anyone who can run `docker run -v /:/host` owns the
# machine), and once this applies `zfs destroy` needs no password either.
# That is why this hook is NOT listed in any postinstall list: it runs
# only when `dj migrate --fix --only sudo-nopasswd-tools` calls it, or when
# you run it by hand. Revoke with `sudo rm` on the drop-in it prints.
#
# The drop-in is validated with `visudo -cf` before it is installed, so a
# bad rule can never land in /etc/sudoers.d and lock sudo out.
#
# Usage:
#   sudo-nopasswd-tools.sh           install / refresh the drop-in
#   sudo-nopasswd-tools.sh --specs   print the sudoers command specs that
#                                    would be granted, one per line, and
#                                    nothing where the rule doesn't apply
#                                    (what the migration's check compares to)
#
# DOTFILES_SUDOERS_DIR exists for tests; a real run never needs to set it.
set -eu

tag='postinstall:sudo-nopasswd-tools'
SUDOERS_DIR="${DOTFILES_SUDOERS_DIR:-/etc/sudoers.d}"

# One spec per installed tool: absolute path, with `wg` limited to `show`.
# Prints nothing -- "not applicable" -- on anything but a Linux box where a
# non-root user has sudo, visudo and a sudoers.d to put the rule in.
specs() {
  [ "$(uname -s)" = Linux ] || return 0
  [ "$(id -u)" -ne 0 ] || return 0
  command -v sudo >/dev/null 2>&1 || return 0
  command -v visudo >/dev/null 2>&1 || return 0
  [ -d "$SUDOERS_DIR" ] || return 0
  for _t in wg docker zfs; do
    _p=$(command -v "$_t" 2>/dev/null) || continue
    case "$_p" in /*) ;; *) continue ;; esac
    if [ "$_t" = wg ]; then printf '%s show *\n' "$_p"; else printf '%s\n' "$_p"; fi
  done
}

case "${1:-}" in
  --specs) specs; exit 0 ;;
  '')      ;;
  *)       printf '[%s] unknown argument: %s\n' "$tag" "$1" >&2; exit 2 ;;
esac

wanted=$(specs)
if [ -z "$wanted" ]; then
  printf '[%s] not applicable here (no wg/docker/zfs, no sudo/visudo, or not Linux); skipping\n' "$tag"
  exit 0
fi

user=$(id -un)
# sudoers.d silently ignores names containing a dot, so sanitize the user.
dropin="$SUDOERS_DIR/dj-nopasswd-$(printf '%s' "$user" | tr -c 'A-Za-z0-9_-' '_')"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT INT TERM
{
  printf '# Managed by dotfiles packages/postinstall/sudo-nopasswd-tools.sh.\n'
  printf '# Remove this file to revoke.\n'
  printf '%s ALL=(root) NOPASSWD: %s\n' "$user" "$(printf '%s\n' "$wanted" | paste -sd, - | sed 's/,/, /g')"
} > "$tmp"

printf '[%s] installing %s:\n' "$tag" "$dropin"
sed 's/^/          /' "$tmp"

if ! sudo visudo -cf "$tmp" >/dev/null; then
  printf '[%s] the generated rule failed visudo validation; not installing it\n' "$tag" >&2
  exit 1
fi

sudo install -m 0440 "$tmp" "$dropin"
printf '[%s] installed; revoke with: sudo rm %s\n' "$tag" "$dropin"
