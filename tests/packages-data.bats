#!/usr/bin/env bats
#
# Format / sanity checks for the packages/ data files. A malformed
# package name silently disappears from the resolved install list,
# so these checks pay for themselves.
#
# Note: packages/template/ is a seed for personal lists (which live in
# the private config repo, outside this repo) -- it's what these checks
# can validate from here.

load test_helper

# Strip comments and blank lines.
pkg_lines() {
  awk 'NF && $1 !~ /^#/' "$1"
}

@test "packages/template/common.txt is non-empty" {
  n=$(pkg_lines "$DOTFILES_REPO_ROOT/packages/template/common.txt" | wc -l)
  [ "$n" -gt 0 ]
}

@test "every template/common.txt entry is a single bare token (no whitespace)" {
  bad=""
  while IFS= read -r line; do
    n_fields=$(printf '%s' "$line" | awk '{print NF}')
    [ "$n_fields" = "1" ] || bad="$bad|$line"
  done < <(pkg_lines "$DOTFILES_REPO_ROOT/packages/template/common.txt")
  if [ -n "$bad" ]; then
    printf 'multi-field entries in template/common.txt:%s\n' "$bad" >&2
    false
  fi
}

@test "no duplicates in packages/template/common.txt" {
  dups=$(pkg_lines "$DOTFILES_REPO_ROOT/packages/template/common.txt" | sort | uniq -d)
  if [ -n "$dups" ]; then
    printf 'duplicates in template/common.txt:\n%s\n' "$dups" >&2
    false
  fi
}

@test "every renames file has exactly 2 fields per entry" {
  for f in "$DOTFILES_REPO_ROOT"/packages/renames/*.txt; do
    [ -e "$f" ] || continue
    bad=$(pkg_lines "$f" | awk 'NF != 2 { print FILENAME ": " $0 }')
    if [ -n "$bad" ]; then
      printf 'malformed lines:\n%s\n' "$bad" >&2
      false
    fi
  done
}

@test "no duplicate logical names in any renames file" {
  for f in "$DOTFILES_REPO_ROOT"/packages/renames/*.txt; do
    [ -e "$f" ] || continue
    dups=$(pkg_lines "$f" | awk '{print $1}' | sort | uniq -d)
    if [ -n "$dups" ]; then
      printf 'duplicate logical names in %s:\n%s\n' "$f" "$dups" >&2
      false
    fi
  done
}
