#!/bin/sh
# Rotate the SOPS age key: generate a new keypair, re-encrypt all secrets,
# update .sops.yaml to reference only the new key, then commit.
# Prints a reminder to distribute the new private key out-of-band.
#
# Two-pass re-encryption avoids a window where secrets are unreadable:
#   pass 1 — both old and new pub key in .sops.yaml; updatekeys adds new key
#             to every encrypted file (both keys accepted)
#   pass 2 — only new pub key in .sops.yaml; updatekeys drops old key
#             (old key still in keys.txt so SOPS can still decrypt for this pass)
# Then keys.txt is replaced with the new keypair.
#
# Limitation: .sops.yaml must have a single age recipient per creation_rules
# entry (the format written by sops-init.sh). Multi-recipient configs need
# manual .sops.yaml editing before running this command.

set -eu

PRIVATE_DIR=${PRIVATE_DIR:-$HOME/.private}
DOT_DIR=${DOT_DIR:-$HOME/.config.git}
AGE_KEY_FILE=${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt
SOPS_YAML=$PRIVATE_DIR/.sops.yaml
SECRETS_DIR=$PRIVATE_DIR/secrets

log() { printf '[rotate-key] %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v age-keygen >/dev/null 2>&1 || die "age-keygen not found; install age first"
command -v sops      >/dev/null 2>&1 || die "sops not found; install sops first"
[ -r "$AGE_KEY_FILE" ] || die "age key not found at $AGE_KEY_FILE; run 'dj sops-init' first"
[ -f "$SOPS_YAML"    ] || die ".sops.yaml not found at $PRIVATE_DIR; run 'dj sops-init' first"

old_pub=$(awk '/^# public key:/ { print $NF; exit }' "$AGE_KEY_FILE")
[ -z "$old_pub" ] && die "could not read public key from $AGE_KEY_FILE"
log "current key: $old_pub"

# Generate new keypair into a temp file; keep old keys.txt intact until
# all files have been re-encrypted.
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT INT TERM
new_key_file=$tmp_dir/keys.txt
umask 077
age-keygen -o "$new_key_file" 2>/dev/null
chmod 600 "$new_key_file"
new_pub=$(awk '/^# public key:/ { print $NF; exit }' "$new_key_file")
[ -z "$new_pub" ] && die "failed to generate new age keypair"
log "new key:     $new_pub"

# Build a sorted list of .enc files to process.
enc_list=$tmp_dir/enc.list
find "$SECRETS_DIR" -name '*.enc' 2>/dev/null | sort > "$enc_list"

updatekeys_all() {
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    ( cd "$PRIVATE_DIR" && SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" \
        sops updatekeys --yes "$f" ) \
      || die "sops updatekeys failed for: $f"
    log "  updated: $(basename "$f")"
  done < "$enc_list"
}

# Pass 1: add new pub key alongside old so both are accepted.
log "pass 1: adding new key to .sops.yaml alongside old key"
sed -i.bak "s|age: ${old_pub}|age: ${old_pub},${new_pub}|g" "$SOPS_YAML"
rm -f "$SOPS_YAML.bak"
[ -s "$enc_list" ] && updatekeys_all

# Pass 2: remove old pub key; re-encrypt to new key only.
# The old key is still in keys.txt, so SOPS can still decrypt for this pass.
log "pass 2: removing old key from .sops.yaml"
sed -i.bak "s|age: ${old_pub},${new_pub}|age: ${new_pub}|g" "$SOPS_YAML"
rm -f "$SOPS_YAML.bak"
[ -s "$enc_list" ] && updatekeys_all

# Install new keypair.
log "installing new key at $AGE_KEY_FILE"
cp "$new_key_file" "$AGE_KEY_FILE"
chmod 600 "$AGE_KEY_FILE"

# Stage .sops.yaml and all re-encrypted files.
log "staging changes"
git --git-dir="$DOT_DIR" --work-tree="$HOME" add "$SOPS_YAML"
while IFS= read -r f; do
  [ -z "$f" ] && continue
  git --git-dir="$DOT_DIR" --work-tree="$HOME" add "$f"
done < "$enc_list"

git --git-dir="$DOT_DIR" --work-tree="$HOME" \
  commit -m "secrets: rotate age key to ${new_pub}"

printf '\n'
printf '=========================================================\n'
printf ' KEY ROTATION COMPLETE\n'
printf '=========================================================\n'
printf '\n'
printf '  New public key: %s\n' "$new_pub"
printf '  Key file:       %s\n' "$AGE_KEY_FILE"
printf '\n'
printf '  REMINDER: distribute the new private key out-of-band\n'
printf '  to every machine that needs to decrypt secrets:\n'
printf '\n'
printf '    %s\n' "$AGE_KEY_FILE"
printf '\n'
printf '  On each machine after receiving the key:\n'
printf '    dj sync\n'
printf '\n'
printf '  Old key (%s)\n' "$old_pub"
printf '  is no longer valid for new encryptions.\n'
printf '=========================================================\n'
