#!/usr/bin/env bats
#
# Coverage for scripts/sync-public.sh -- the "fast-forward ~/.dotfiles"
# half of `dj sync` -- and for how the Justfile wires it (and the closing
# migration report) into `sync` and `upgrade`.
#
# The script's contract is "warn, never fail": the checkout it updates is
# also where tooling gets edited, so diverged / dirty / offline are normal
# states. Nearly every test below therefore asserts exit 0 AND that the
# local checkout was left exactly as it was.

load test_helper

SYNC_PUBLIC="$DOTFILES_REPO_ROOT/scripts/sync-public.sh"
REAL_JUSTFILE="$DOTFILES_REPO_ROOT/Justfile"

setup() {
  sandbox_setup
  UPSTREAM="$SANDBOX/upstream"
  CLONE="$SANDBOX/dotfiles"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e.com

  git init -q -b master "$UPSTREAM"
  echo one > "$UPSTREAM/file"
  git -C "$UPSTREAM" add file
  git -C "$UPSTREAM" commit -q -m 'initial'
  git clone -q "$UPSTREAM" "$CLONE"
  export DOTFILES_REPO_ROOT="$CLONE"
}

teardown() {
  sandbox_teardown
}

# Commit FILE=CONTENT on the upstream with message MSG.
upstream_commit() {
  printf '%s\n' "$2" > "$UPSTREAM/$1"
  git -C "$UPSTREAM" add "$1"
  git -C "$UPSTREAM" commit -q -m "$3"
}

# Commit FILE=CONTENT in the local clone with message MSG.
local_commit() {
  printf '%s\n' "$2" > "$CLONE/$1"
  git -C "$CLONE" add "$1"
  git -C "$CLONE" commit -q -m "$3"
}

head_of() { git -C "$1" rev-parse HEAD; }

# Put a copy of the real script at <repo>/scripts/sync-public.sh in both
# repos, the layout the real thing has, so it can be run from inside the
# checkout it is updating.
vendor_script() {
  mkdir -p "$UPSTREAM/scripts"
  cp "$SYNC_PUBLIC" "$UPSTREAM/scripts/sync-public.sh"
  git -C "$UPSTREAM" add scripts
  git -C "$UPSTREAM" commit -q -m 'vendor the script'
  git -C "$CLONE" pull -q --ff-only
}

# --- updating ---------------------------------------------------------------

@test "sync-public: fast-forwards when upstream has new commits" {
  upstream_commit file two 'add the second thing'
  run sh "$SYNC_PUBLIC"
  [ "$status" -eq 0 ]
  [ "$(head_of "$CLONE")" = "$(head_of "$UPSTREAM")" ]
  [[ "$output" == *"updated: 1 new commit(s)"* ]]
  [[ "$output" == *"add the second thing"* ]]
}

@test "sync-public: reports up to date when there is nothing to pull" {
  before=$(head_of "$CLONE")
  run sh "$SYNC_PUBLIC"
  [ "$status" -eq 0 ]
  [ "$(head_of "$CLONE")" = "$before" ]
  [[ "$output" == *"already up to date"* ]]
}

@test "sync-public: a long update lists the newest 10 and counts the rest" {
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    upstream_commit file "v$i" "commit number $i"
  done
  run sh "$SYNC_PUBLIC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"12 new commit(s)"* ]]
  [[ "$output" == *"commit number 12"* ]]
  [[ "$output" == *"and 2 more"* ]]
  [[ "$output" != *"commit number 2"$'\n'* ]]
}

@test "sync-public: unpushed local commits are not a problem and are kept" {
  local_commit mine hello 'local only'
  before=$(head_of "$CLONE")
  run sh "$SYNC_PUBLIC"
  [ "$status" -eq 0 ]
  [ "$(head_of "$CLONE")" = "$before" ]
  [[ "$output" == *"already up to date"* ]]
}

@test "sync-public: uncommitted changes in unrelated files survive the pull" {
  upstream_commit other 'from upstream' 'upstream adds other'
  echo 'my edit' >> "$CLONE/file"
  run sh "$SYNC_PUBLIC"
  [ "$status" -eq 0 ]
  [ -f "$CLONE/other" ]
  grep -qx 'my edit' "$CLONE/file"
}

@test "sync-public: derives the repo from its own location when unset" {
  vendor_script
  upstream_commit file two 'bump'
  unset DOTFILES_REPO_ROOT
  run sh "$CLONE/scripts/sync-public.sh"
  [ "$status" -eq 0 ]
  [ "$(head_of "$CLONE")" = "$(head_of "$UPSTREAM")" ]
}

@test "sync-public: survives a pull that replaces the running script" {
  vendor_script
  # Upstream swaps in a completely different (and much shorter) file.
  printf '#!/bin/sh\necho REPLACED\n' > "$UPSTREAM/scripts/sync-public.sh"
  git -C "$UPSTREAM" commit -q -am 'rewrite the script'
  unset DOTFILES_REPO_ROOT
  run sh "$CLONE/scripts/sync-public.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated: 1 new commit(s)"* ]]
  [[ "$output" != *"REPLACED"* ]]
  grep -q REPLACED "$CLONE/scripts/sync-public.sh"
}

# --- warn, never fail -------------------------------------------------------

@test "sync-public: diverged history warns, exits 0, and changes nothing" {
  local_commit mine hello 'local only'
  upstream_commit file two 'upstream moved'
  before=$(head_of "$CLONE")
  run sh "$SYNC_PUBLIC"
  [ "$status" -eq 0 ]
  [ "$(head_of "$CLONE")" = "$before" ]
  [[ "$output" == *"could not fast-forward"* ]]
  [[ "$output" == *"git pull --rebase"* ]]
}

@test "sync-public: a local edit that the pull would overwrite is kept, with a warning" {
  upstream_commit file two 'upstream edits file'
  echo 'conflicting local edit' > "$CLONE/file"
  before=$(head_of "$CLONE")
  run sh "$SYNC_PUBLIC"
  [ "$status" -eq 0 ]
  [ "$(head_of "$CLONE")" = "$before" ]
  grep -qx 'conflicting local edit' "$CLONE/file"
  [[ "$output" == *"could not fast-forward"* ]]
}

@test "sync-public: an unreachable remote warns and exits 0" {
  git -C "$CLONE" remote set-url origin "$SANDBOX/does-not-exist"
  before=$(head_of "$CLONE")
  run sh "$SYNC_PUBLIC"
  [ "$status" -eq 0 ]
  [ "$(head_of "$CLONE")" = "$before" ]
  [[ "$output" == *"could not fast-forward"* ]]
}

@test "sync-public: a branch with no upstream is skipped with a warning" {
  git -C "$CLONE" checkout -q -b lonely
  run sh "$SYNC_PUBLIC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no upstream"* ]]
  [[ "$output" == *"lonely"* ]]
}

@test "sync-public: a detached HEAD is skipped with a warning" {
  git -C "$CLONE" checkout -q --detach
  run sh "$SYNC_PUBLIC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"detached HEAD"* ]]
}

@test "sync-public: a non-git directory is skipped" {
  mkdir "$SANDBOX/tarball"
  DOTFILES_REPO_ROOT="$SANDBOX/tarball" run sh "$SYNC_PUBLIC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a git checkout"* ]]
}

@test "sync-public: an unpacked copy inside some OTHER repo is not pulled" {
  # rev-parse would find the enclosing repo and pull THAT one.
  mkdir -p "$CLONE/vendored/dotfiles"
  upstream_commit file two 'upstream moved'
  before=$(head_of "$CLONE")
  DOTFILES_REPO_ROOT="$CLONE/vendored/dotfiles" run sh "$SYNC_PUBLIC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a git checkout"* ]]
  [ "$(head_of "$CLONE")" = "$before" ]
}

# --- Justfile wiring --------------------------------------------------------

# The N-th line (1-based) of $output that matches PATTERN, as a line number
# into $output -- used to assert ordering of the printed recipe commands.
line_of() { printf '%s\n' "$output" | grep -n -- "$1" | head -1 | cut -d: -f1; }

dry_run() {
  run just --justfile "$REAL_JUSTFILE" --dry-run "$1"
  [ "$status" -eq 0 ]
}

@test "just sync: public pull, private pull, secrets, keys, then migration report" {
  dry_run sync
  a=$(line_of 'sync-public.sh')
  b=$(line_of 'pull --rebase')
  c=$(line_of 'apply-secrets')
  d=$(line_of 'authorized-keys.sh')
  e=$(line_of 'migrate.sh" --quiet')
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ -n "$e" ]
  [ "$a" -lt "$b" ]
  [ "$b" -lt "$c" ]
  [ "$c" -lt "$d" ]
  [ "$d" -lt "$e" ]
}

@test "just sync: stays sudo-free -- no package install, no post-install hooks" {
  dry_run sync
  [[ "$output" != *"install-packages.sh"* ]]
  [[ "$output" != *"run-postinstall.sh"* ]]
}

@test "just sync: the migration report can never fail the recipe" {
  dry_run sync
  [[ "$output" == *'migrate.sh" --quiet || true'* ]]
}

@test "just upgrade: same pull, then installs, and reports migrations LAST" {
  dry_run upgrade
  a=$(line_of 'sync-public.sh')
  b=$(line_of 'pull --rebase')
  c=$(line_of 'install-packages.sh')
  d=$(line_of 'run-postinstall.sh')
  e=$(line_of 'migrate.sh" --quiet')
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ -n "$e" ]
  [ "$a" -lt "$b" ]
  [ "$b" -lt "$c" ]
  [ "$c" -lt "$d" ]
  [ "$d" -lt "$e" ]
}

@test "just upgrade: pulls and reports exactly once (no doubled sync)" {
  dry_run upgrade
  [ "$(printf '%s\n' "$output" | grep -c 'sync-public.sh')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c 'migrate.sh')" -eq 1 ]
}

@test "just: the internal recipes stay out of the public listing" {
  run just --justfile "$REAL_JUSTFILE" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"sync"* ]]
  [[ "$output" != *"_pull"* ]]
  [[ "$output" != *"_migrate-report"* ]]
}
