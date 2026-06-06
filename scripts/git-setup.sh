#!/bin/sh
# First-run git setup: identity, SSH key, GPG key.
#
# Usage: git-setup.sh [--yes | --no]
#
# Idempotent: each step is skipped when already complete.
#   - git user.name / user.email: adopted if already set; prompted otherwise
#   - SSH key: generated at ~/.ssh/id_ed25519 only if absent
#   - GPG key: generated only if no secret keys exist; git configured to
#     use it only when this script is the one that created it
#
# Pass --yes to skip the identity prompt (non-interactive use with
# existing config). Pass --no to do nothing.

set -eu

DOT_DIR=${DOT_DIR:-$HOME/.config.git}
SETUP=ask

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) SETUP=yes ;;
    --no)  SETUP=no ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      exit 2 ;;
  esac
  shift
done

log() { printf '[git-setup] %s\n' "$*"; }
dot() { git --git-dir="$DOT_DIR" --work-tree="$HOME" "$@"; }

[ "$SETUP" = no ] && exit 0

# ---------- Git identity ----------

git_name=$(git config --global user.name  2>/dev/null || true)
git_email=$(git config --global user.email 2>/dev/null || true)

if [ -n "$git_name" ] && [ -n "$git_email" ]; then
  log "git identity already configured: $git_name <$git_email>"
else
  if [ -t 0 ] && [ -t 1 ] && [ "$SETUP" = ask ]; then
    printf '\n[git-setup] Git identity not fully configured.\n'
    if [ -z "$git_name" ]; then
      printf '[git-setup] Name (for git commits): '
      read -r git_name || git_name=
    fi
    if [ -z "$git_email" ]; then
      printf '[git-setup] Email (for git commits): '
      read -r git_email || git_email=
    fi
  fi
  [ -n "$git_name"  ] && git config --global user.name  "$git_name"
  [ -n "$git_email" ] && git config --global user.email "$git_email"
  if [ -n "$git_name" ] || [ -n "$git_email" ]; then
    log "set git identity: ${git_name:-<not set>} <${git_email:-not set}>"
  fi
fi

# Useful global defaults (idempotent).
git config --global push.autoSetupRemote true

# ---------- SSH key ----------

ssh_key="$HOME/.ssh/id_ed25519"

if [ -f "$ssh_key" ]; then
  log "SSH key already exists at $ssh_key"
elif ! command -v ssh-keygen >/dev/null 2>&1; then
  log "ssh-keygen not found; skipping SSH key generation"
else
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  _comment="${git_email:-$(id -un)@$(hostname -s 2>/dev/null || hostname)}"
  ssh-keygen -t ed25519 -C "$_comment" -f "$ssh_key" -N ""
  log "generated SSH key at $ssh_key"
  log "public key: $(cat "${ssh_key}.pub")"
fi

# ---------- GPG key ----------

gpg_key_created=

if ! command -v gpg >/dev/null 2>&1; then
  log "gpg not found; skipping GPG key setup"
elif gpg --list-secret-keys --keyid-format LONG 2>/dev/null | grep -q '^sec'; then
  log "GPG secret key already exists; not generating a new one"
elif [ -z "$git_name" ] || [ -z "$git_email" ]; then
  log "git identity not set; skipping GPG key generation"
else
  log "generating GPG key for $git_name <$git_email> (this may take a moment)"
  gpg --batch --passphrase '' \
    --quick-gen-key "$git_name <$git_email>" rsa4096 sign 0
  gpg_key_created=1
  log "GPG key generated"
fi

# Configure git signing only for a key we just created.
if [ -n "$gpg_key_created" ] && [ -n "$git_email" ]; then
  _gpg_id=$(gpg --list-secret-keys --keyid-format LONG "$git_email" 2>/dev/null \
    | awk '/^sec/ { split($2, a, "/"); print a[2]; exit }')
  if [ -n "$_gpg_id" ]; then
    git config --global user.signingkey "$_gpg_id"
    git config --global commit.gpgsign true
    log "configured git to sign commits with GPG key $_gpg_id"
  fi
fi

# ---------- Stage into private bare repo ----------

if [ -d "$DOT_DIR" ]; then
  [ -f "$HOME/.gitconfig" ]       && dot add "$HOME/.gitconfig"
  [ -f "${ssh_key}.pub" ]         && dot add "${ssh_key}.pub"
  log "staged .gitconfig and SSH public key"
fi
