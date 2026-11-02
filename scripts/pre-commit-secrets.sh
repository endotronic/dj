#!/bin/sh
# Pre-commit hook: reject any plaintext file staged under .private/secrets/.
#
# Allowed under .private/secrets/:
#   *.enc       SOPS-encrypted (the real source of truth)
#   *.pub       Public keys, safe in cleartext
#   *.md        Documentation
#   *.example   Format-only example files (no real secrets)
#   .gitkeep    Directory placeholders
#
# Anything else is presumed sensitive and rejected. Override with
# `git commit --no-verify` only when you're sure.

set -eu

bad_list=$(mktemp)
trap 'rm -f "$bad_list"' EXIT INT TERM

git diff --cached --name-only --diff-filter=ACMR | while IFS= read -r f; do
  case "$f" in
    .private/secrets/*)
      case "$f" in
        *.enc|*.pub|*.md|*.example|*/.gitkeep) ;;
        *) printf '%s\n' "$f" ;;
      esac
      ;;
  esac
done > "$bad_list"

n_bad=$(awk 'END { print NR+0 }' "$bad_list")

if [ "$n_bad" -gt 0 ]; then
  printf 'pre-commit: %s plaintext file(s) staged under .private/secrets/:\n' "$n_bad" >&2
  sed 's/^/  /' < "$bad_list" >&2
  cat >&2 <<'EOF'

These look like they should be encrypted. Either:
  sops -e <file> > <file>.enc && rm <file>     encrypt to .enc
  git restore --staged <file>                   unstage

If you intend cleartext (a .md doc, a .pub key, an .example, or
.gitkeep), check the suffix and try again.
EOF
  exit 1
fi
