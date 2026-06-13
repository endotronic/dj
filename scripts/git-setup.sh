#!/bin/sh
# First-run git setup: identity, SSH key, GPG key.
#
# Usage: git-setup.sh [--yes | --no]
#
# Idempotent: each step is skipped when already complete.
#   - git user.name / user.email: adopted if already set; prompted otherwise
#   - SSH key: generated at ~/.ssh/id_ed25519 only if absent (rebuild-secrets.sh
#     restores it first if the private repo has one registered)
#   - GPG key: generated only if no secret keys exist (rebuild-secrets.sh
#     imports one first if the private repo has one registered); git
#     configured to sign with it if this script created or restored it
#     and signing isn't already configured
#
# When a new SSH or GPG key is generated here (i.e. nothing was restored
# from the private repo) and the SOPS/age secrets infrastructure is ready,
# interactively offers to register the new private key via secret-add.sh
# so other machines can restore it instead of generating their own.
#
# Pass --yes to skip the identity prompt (non-interactive use with
# existing config). Pass --no to do nothing.

set -eu

DOT_DIR=${DOT_DIR:-$HOME/.config.git}
PRIVATE_DIR=${PRIVATE_DIR:-$HOME/.private}
AGE_KEY=${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt
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

# True if we can prompt the user, even when stdin is consumed by a
# pipe (curl | sh): requires stdout to be a terminal and /dev/tty to
# be openable for reading. Reads in the calling block should
# redirect from `/dev/tty` directly (a regular builtin like `read`,
# so a redirection failure there is a normal nonzero exit -- unlike
# `exec`, which would abort the whole script under `set -e`).
can_prompt() {
  [ -t 1 ] && true 2>/dev/null </dev/tty
}

# True if the SOPS/age secrets infrastructure is ready to encrypt a new
# secret (private bare repo present, sops on PATH, age key and
# .sops.yaml readable).
secrets_ready() {
  [ -d "$DOT_DIR" ] \
    && command -v sops >/dev/null 2>&1 \
    && [ -r "$AGE_KEY" ] \
    && [ -f "$PRIVATE_DIR/.sops.yaml" ]
}

# Ask whether to register a freshly-generated private key as an
# encrypted secret. Returns 0 (yes) only when the infrastructure is
# ready, we can prompt, and the user confirms; 1 otherwise.
confirm_register() {
  secrets_ready || return 1
  [ "$SETUP" = ask ] && can_prompt || return 1
  printf '[git-setup] Register %s as an encrypted secret for other machines? [y/N]: ' "$1"
  read -r _confirm_ans </dev/tty || _confirm_ans=
  case "$_confirm_ans" in
    y|Y|yes) return 0 ;;
    *)       return 1 ;;
  esac
}

[ "$SETUP" = no ] && exit 0

# ---------- Git identity ----------

git_name=$(git config --global user.name  2>/dev/null || true)
git_email=$(git config --global user.email 2>/dev/null || true)

if [ -n "$git_name" ] && [ -n "$git_email" ]; then
  log "git identity already configured: $git_name <$git_email>"
else
  if [ "$SETUP" = ask ] && can_prompt; then
    printf '\n[git-setup] Git identity not fully configured.\n'
    if [ -z "$git_name" ]; then
      printf '[git-setup] Name (for git commits): '
      read -r git_name </dev/tty || git_name=
    fi
    if [ -z "$git_email" ]; then
      printf '[git-setup] Email (for git commits): '
      read -r git_email </dev/tty || git_email=
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
  _comment="${git_email:-$(id -un)@$(hostname -s 2>/dev/null || uname -n 2>/dev/null || echo unknown)}"
  ssh-keygen -t ed25519 -C "$_comment" -f "$ssh_key" -N ""
  log "generated SSH key at $ssh_key"
  log "public key: $(cat "${ssh_key}.pub")"

  if confirm_register "SSH private key ($ssh_key)"; then
    sh "$HOME/.dotfiles/scripts/secret-add.sh" "$ssh_key"
  else
    log "skipped registering SSH key; run 'dj secret-add $ssh_key' to share it with other machines"
  fi
fi

# ---------- GPG key ----------

gpg_key_created=
gpg_key_imported=
[ -r "$HOME/.private/gpg/private-key.asc" ] && gpg_key_imported=1

if ! command -v gpg >/dev/null 2>&1; then
  log "gpg not found; skipping GPG key setup"
elif gpg --list-secret-keys --keyid-format LONG 2>/dev/null | grep -q '^sec'; then
  if [ -n "$gpg_key_imported" ]; then
    log "GPG secret key restored from private repo"
  else
    log "GPG secret key already exists; not generating a new one"
  fi
elif [ -z "$git_name" ] || [ -z "$git_email" ]; then
  log "git identity not set; skipping GPG key generation"
else
  log "generating GPG key for $git_name <$git_email> (this may take a moment)"
  gpg --batch --passphrase '' \
    --quick-gen-key "$git_name <$git_email>" rsa4096 sign 0
  gpg_key_created=1
  log "GPG key generated"
fi

# Find the secret key matching this identity, if any -- covers keys we
# just created and keys restored from the private repo.
_gpg_id=
if command -v gpg >/dev/null 2>&1 && [ -n "$git_email" ]; then
  _gpg_id=$(gpg --list-secret-keys --keyid-format LONG "$git_email" 2>/dev/null \
    | awk '/^sec/ { split($2, a, "/"); print a[2]; exit }')
fi

# Configure git signing for that key, but only when this script created
# or restored it, and only if signing isn't already configured (don't
# clobber an existing unrelated setup).
if [ -n "$_gpg_id" ] \
   && { [ -n "$gpg_key_created" ] || [ -n "$gpg_key_imported" ]; } \
   && [ -z "$(git config --global user.signingkey 2>/dev/null || true)" ]; then
  git config --global user.signingkey "$_gpg_id"
  git config --global commit.gpgsign true
  log "configured git to sign commits with GPG key $_gpg_id"
fi

# Offer to register a freshly-generated GPG key (nothing was restored
# from the private repo, so there's nothing to share with other
# machines yet).
if [ -n "$gpg_key_created" ] && [ -n "$_gpg_id" ]; then
  if confirm_register "GPG private key $_gpg_id"; then
    _tmpkey=$(mktemp)
    _tmptrust=$(mktemp)
    gpg --export-secret-keys --armor "$_gpg_id" > "$_tmpkey"
    gpg --export-ownertrust > "$_tmptrust"
    sh "$HOME/.dotfiles/scripts/secret-add.sh" "$_tmpkey"   "$HOME/.private/gpg/private-key.asc" 0600
    sh "$HOME/.dotfiles/scripts/secret-add.sh" "$_tmptrust" "$HOME/.private/gpg/ownertrust.txt"   0600
    shred -u "$_tmpkey" "$_tmptrust" 2>/dev/null || rm -f "$_tmpkey" "$_tmptrust"
  else
    log "skipped registering GPG key; run 'dj secret-add' to share it with other machines"
  fi
fi

# ---------- Stage into private bare repo ----------

if [ -d "$DOT_DIR" ]; then
  [ -f "$HOME/.gitconfig" ]       && dot add "$HOME/.gitconfig"
  [ -f "${ssh_key}.pub" ]         && dot add "${ssh_key}.pub"
  log "staged .gitconfig and SSH public key"
fi
