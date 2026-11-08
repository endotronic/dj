#!/bin/sh
# Git hook for the public dj repo: refuse a commit that contains anything
# from your own denylist (your username, domains, hostnames, ...).
#
# Installed as both .git/hooks/pre-commit (scans the lines being added)
# and .git/hooks/commit-msg (scans the message, passed as $1), by
# scripts/install-public-hooks.sh.
#
# The denylist is a file of one fixed string per line (blank lines and
# lines starting with # are ignored), matched case-insensitively on word
# boundaries. It lives in YOUR private repo, never here, because the list
# of things not to publish is itself personal:
#
#   $DJ_PERSONAL_DENYLIST, else ~/.config/dj/personal-denylist.txt
#
# No denylist, no checks: the hook is a no-op for everyone else.
# Override once, when you are sure, with `git commit --no-verify`.

set -eu

LIST=${DJ_PERSONAL_DENYLIST:-${XDG_CONFIG_HOME:-$HOME/.config}/dj/personal-denylist.txt}
[ -f "$LIST" ] || exit 0

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$LIST" > "$tmp/patterns" || true
[ -s "$tmp/patterns" ] || exit 0

if [ $# -gt 0 ]; then
  # commit-msg: the message, minus git's own comment lines.
  where="commit message"
  grep -v '^#' "$1" > "$tmp/text" || true
  awk '{ print "commit message" }' "$tmp/text" > "$tmp/where"
else
  where="staged changes"
  # Added lines only, each paired with the file it is in.
  git diff --cached -U0 --no-color --diff-filter=ACMR | awk -v T="$tmp/text" -v W="$tmp/where" '
    /^\+\+\+ / { f = substr($0, 7); next }
    /^\+/      { print substr($0, 2) > T; print f > W }
  '
  : >> "$tmp/text"; : >> "$tmp/where"
fi

grep -n -i -w -F -f "$tmp/patterns" "$tmp/text" > "$tmp/hits" || exit 0

printf 'personal-guard: this looks personal; the public repo takes nothing from the denylist (%s):\n' "$LIST" >&2
while IFS=: read -r n rest; do
  printf '  %s:%s: %s\n' "$(sed -n "${n}p" "$tmp/where")" "$n" "$rest" >&2
done < "$tmp/hits"
cat >&2 <<EOT

In $where. Use a placeholder (alice, host1, example.com), or move the
change to your private repo (dot). If it is not actually personal,
\`git commit --no-verify\` overrides this once.
EOT
exit 1
