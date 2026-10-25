#!/bin/sh
# Install the Open Remote - SSH extension (jeanp413.open-remote-ssh, from
# Open VSX) into whichever open-source VS Code build is installed: code-oss
# (Arch) and/or codium (VSCodium, elsewhere -- see packages/scripts/code-oss.sh).
# It is the Open VSX stand-in for Microsoft's proprietary Remote - SSH.
#
# code-oss additionally needs the extension enabled for the proposed API it
# uses, via "enable-proposed-api" in ~/.vscode-oss/argv.json; without that it
# installs but never activates. VSCodium doesn't need it (since 1.75). That
# file is JSONC, so it is only edited in the one way that is safe to do by
# text: create it if missing, or insert the key right after the opening `{`.
# Anything else (the key already present with other entries, an unusual
# layout) is reported with the exact line to add, never rewritten.
#
# Idempotent. Needs network for the install; a failed install warns and
# exits non-zero so the next run retries.
#
# DOTFILES_VSCODE_ARGV overrides the argv.json path, for tests.
set -eu

tag='postinstall:open-remote-ssh'
ext='jeanp413.open-remote-ssh'
argv="${DOTFILES_VSCODE_ARGV:-$HOME/.vscode-oss/argv.json}"

found=0
rc=0

for editor in code-oss codium; do
  command -v "$editor" >/dev/null 2>&1 || continue
  found=1

  if "$editor" --list-extensions 2>/dev/null | grep -qix "$ext"; then
    printf '[%s] %s already has %s\n' "$tag" "$editor" "$ext"
  else
    printf '[%s] installing %s into %s\n' "$tag" "$ext" "$editor"
    if ! "$editor" --install-extension "$ext"; then
      printf '[%s] WARNING: %s could not install %s\n' "$tag" "$editor" "$ext" >&2
      rc=1
    fi
  fi

  [ "$editor" = code-oss ] || continue

  if [ ! -e "$argv" ]; then
    mkdir -p "$(dirname "$argv")"
    printf '{\n    "enable-proposed-api": ["%s"]\n}\n' "$ext" > "$argv"
    printf '[%s] created %s\n' "$tag" "$argv"
  elif grep -qF "$ext" "$argv"; then
    printf '[%s] %s already enables %s\n' "$tag" "$argv" "$ext"
  elif grep -qF '"enable-proposed-api"' "$argv"; then
    printf '[%s] WARNING: add "%s" to the existing "enable-proposed-api" list in %s by hand\n' "$tag" "$ext" "$argv" >&2
    rc=1
  else
    tmp=$(mktemp)
    awk -v ext="$ext" '
      !done && /^[ \t]*\{[ \t]*$/ { print; printf "    \"enable-proposed-api\": [\"%s\"],\n", ext; done = 1; next }
      { print }
      END { exit !done }
    ' "$argv" > "$tmp" || {
      rm -f "$tmp"
      printf '[%s] WARNING: unrecognised layout in %s; add "enable-proposed-api": ["%s"] by hand\n' "$tag" "$argv" "$ext" >&2
      rc=1
      continue
    }
    cp "$argv" "$argv.dj-backup"
    mv "$tmp" "$argv"
    printf '[%s] added "enable-proposed-api" to %s (backup: %s.dj-backup)\n' "$tag" "$argv" "$argv"
  fi
done

[ "$found" -eq 1 ] || printf '[%s] neither code-oss nor codium is installed; skipping\n' "$tag"
exit "$rc"
