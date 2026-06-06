#!/usr/bin/env bats
#
# Tests for install.sh. The big-ticket coverage is conflict
# detection: identical files aren't conflicts, differing files
# are, and the three --on-conflict modes (backup / keep / abort)
# leave the right end state.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  stub_sudo_passthrough          # in case the script ever needs sudo
  export INSTALL="$DOTFILES_REPO_ROOT/install.sh"
}

teardown() {
  sandbox_teardown
}

# --- argument validation --------------------------------------------------

@test "--help exits 0 and prints usage" {
  run sh "$INSTALL" --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ Usage ]]
  [[ "$output" =~ "--system-type" ]]
  [[ "$output" =~ "--on-conflict" ]]
  [[ "$output" =~ "--age-key" ]]
}

@test "invalid --system-type exits 2" {
  run sh "$INSTALL" --system-type bogus
  [ "$status" -eq 2 ]
  [[ "$output" =~ "--system-type must be" ]]
}

@test "invalid --on-conflict exits 2" {
  run sh "$INSTALL" --on-conflict bogus
  [ "$status" -eq 2 ]
  [[ "$output" =~ "--on-conflict must be" ]]
}

@test "unknown argument exits 2" {
  run sh "$INSTALL" --not-a-flag
  [ "$status" -eq 2 ]
  [[ "$output" =~ "unknown argument" ]]
}

# --- fresh checkout into empty $HOME --------------------------------------

@test "fresh install into empty HOME checks out tracked files" {
  make_src_repo
  add_to_repo .bashrc "# tracked bashrc"
  add_to_repo .config/foo.toml "key = 1"
  publish_repo

  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict backup
  [ "$status" -eq 0 ]
  [ -d "$HOME/.config.git" ]
  [ -f "$HOME/.bashrc" ]
  [ -f "$HOME/.config/foo.toml" ]
  grep -q "tracked bashrc" "$HOME/.bashrc"
}

@test "fresh install reports 'no conflicts' when HOME is empty" {
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo
  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict abort
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no conflicts" ]]
}

# --- conflict detection ----------------------------------------------------

@test "identical-content files are NOT conflicts" {
  make_src_repo
  add_to_repo .bashrc "# same on both sides"
  publish_repo
  # Pre-populate $HOME with the EXACT same content.
  printf '%s\n' "# same on both sides" > "$HOME/.bashrc"

  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict abort
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no conflicts" ]]
  # File unchanged.
  grep -q "same on both sides" "$HOME/.bashrc"
}

@test "differing files ARE conflicts" {
  make_src_repo
  add_to_repo .bashrc "# tracked version"
  publish_repo
  printf '%s\n' "# DIFFERENT user version" > "$HOME/.bashrc"

  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict abort
  [ "$status" -eq 1 ]
  [[ "$output" =~ ".bashrc" ]]
}

@test "symlinks in HOME are skipped (not flagged as conflicts)" {
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo
  # User has a symlink at .bashrc pointing elsewhere.
  printf 'other\n' > "$HOME/.other-bashrc"
  ln -s "$HOME/.other-bashrc" "$HOME/.bashrc"

  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict abort
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no conflicts" ]]
}

# --- --on-conflict backup -------------------------------------------------

@test "--on-conflict backup moves originals and writes tracked versions" {
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo
  printf '%s\n' "# user" > "$HOME/.bashrc"

  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict backup
  [ "$status" -eq 0 ]
  grep -q "^# tracked" "$HOME/.bashrc"
  # The user version is preserved in the backup tree.
  found=$(find "$HOME/.dotfiles-backup" -name .bashrc -type f | head -1)
  [ -n "$found" ]
  grep -q "^# user" "$found"
}

# --- --on-conflict keep ---------------------------------------------------

@test "--on-conflict keep preserves user version; backup has user copy too" {
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo
  printf '%s\n' "# user" > "$HOME/.bashrc"

  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict keep
  [ "$status" -eq 0 ]
  # User version still in place.
  grep -q "^# user" "$HOME/.bashrc"
  # Backup also has the user version (the moved-aside copy).
  found=$(find "$HOME/.dotfiles-backup" -name .bashrc -type f | head -1)
  [ -n "$found" ]
  grep -q "^# user" "$found"
}

@test "--on-conflict keep leaves the file as modified per dot status" {
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo
  printf '%s\n' "# user" > "$HOME/.bashrc"

  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict keep
  [ "$status" -eq 0 ]
  # `dot status` should report .bashrc as modified.
  run dot status --porcelain
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[[:space:]]?M[[:space:]].bashrc ]] || \
    [[ "$output" =~ M\ .bashrc ]]
}

# --- --on-conflict abort --------------------------------------------------

@test "--on-conflict abort exits 1 and leaves HOME untouched" {
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo
  printf '%s\n' "# user" > "$HOME/.bashrc"

  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict abort
  [ "$status" -eq 1 ]
  grep -q "^# user" "$HOME/.bashrc"
  [ ! -d "$HOME/.dotfiles-backup" ]
}

# --- non-interactive guard -------------------------------------------------

@test "--on-conflict ask refuses to act when non-interactive and conflicts exist" {
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo
  printf '%s\n' "# user" > "$HOME/.bashrc"

  # `run` gives no controlling TTY, so this exercises the
  # non-interactive guard.
  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict ask
  [ "$status" -eq 1 ]
  [[ "$output" =~ "non-interactive" ]]
  # HOME unchanged.
  grep -q "^# user" "$HOME/.bashrc"
}

# --- system-type persistence ---------------------------------------------

@test "--system-type desktop writes the tier file" {
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo

  run sh "$INSTALL" --repo "$SRC_REPO" --system-type desktop --on-conflict backup
  [ "$status" -eq 0 ]
  [ -f "$XDG_CONFIG_HOME/dotfiles/system-type" ]
  [ "$(cat "$XDG_CONFIG_HOME/dotfiles/system-type")" = "desktop" ]
}

@test "re-running without --system-type preserves the previous tier" {
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo

  sh "$INSTALL" --repo "$SRC_REPO" --system-type server --on-conflict backup >/dev/null
  # Re-run without the flag.
  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict backup
  [ "$status" -eq 0 ]
  [ "$(cat "$XDG_CONFIG_HOME/dotfiles/system-type")" = "server" ]
}

# --- idempotency ---------------------------------------------------------

# --- auto-detection of source repo (when --repo not given) ----------------

# Build a fake "our repo" at $1 containing the minimum structure
# auto-detection looks for. Returns 0 on success.
_make_fake_our_repo() {
  local where=$1
  mkdir -p "$where/.dotfiles/scripts"
  cp "$DOTFILES_REPO_ROOT/install.sh"            "$where/.dotfiles/install.sh"
  cp "$DOTFILES_REPO_ROOT/scripts/os-detect.sh"  "$where/.dotfiles/scripts/os-detect.sh"
  # Track a single .bashrc so the bare repo isn't empty.
  printf '# fake bashrc\n' > "$where/.bashrc"
  ( cd "$where" \
      && git init -q \
      && git config user.email t@t \
      && git config user.name t \
      && git config commit.gpgsign false \
      && git add -A \
      && git commit -q -m init )
}

@test "auto-detect: install.sh inside its own clone uses that clone as default" {
  fake=$SANDBOX/fake-our-repo
  _make_fake_our_repo "$fake"

  run sh "$fake/.dotfiles/install.sh" --on-conflict backup --remove-source no
  [ "$status" -eq 0 ]
  [[ "$output" =~ "auto-detected source repo: $fake" ]]
  [[ "$output" =~ "REPO=$fake" ]]
  # And the bare repo's HEAD really came from the fake repo.
  grep -q "fake bashrc" "$HOME/.bashrc"
}

@test "auto-detect: --repo takes priority over auto-detection" {
  fake=$SANDBOX/fake-our-repo
  _make_fake_our_repo "$fake"
  # A separate src repo to point --repo at.
  other=$SANDBOX/other-repo
  mkdir -p "$other"
  ( cd "$other" \
      && git init -q \
      && git config user.email t@t \
      && git config user.name t \
      && git config commit.gpgsign false )
  printf '# OTHER bashrc\n' > "$other/.bashrc"
  ( cd "$other" && git add -A && git commit -q -m init )

  run sh "$fake/.dotfiles/install.sh" --repo "$other" \
    --on-conflict backup --remove-source no
  [ "$status" -eq 0 ]
  # Should NOT auto-detect, REPO is the --repo path.
  if [[ "$output" =~ "auto-detected source repo" ]]; then
    printf 'unexpected auto-detect when --repo was explicit\n%s\n' "$output" >&2
    false
  fi
  [[ "$output" =~ "REPO=$other" ]]
  grep -q "OTHER bashrc" "$HOME/.bashrc"
}

@test "auto-detect: script outside any git repo falls back to default URL" {
  # Place install.sh in /tmp-style location not under any git dir.
  outside=$SANDBOX/free-standing
  mkdir -p "$outside/.dotfiles/scripts"
  cp "$DOTFILES_REPO_ROOT/install.sh"           "$outside/.dotfiles/install.sh"
  cp "$DOTFILES_REPO_ROOT/scripts/os-detect.sh" "$outside/.dotfiles/scripts/os-detect.sh"
  # NO git init -- this dir is not a repo.

  # Have to give DOTFILES_REPO_URL so the fallback resolves to
  # something cloneable for the test (clone of our fake repo).
  fake=$SANDBOX/clonable
  _make_fake_our_repo "$fake"
  export DOTFILES_REPO_URL=$fake

  run sh "$outside/.dotfiles/install.sh" --on-conflict backup --remove-source no
  [ "$status" -eq 0 ]
  if [[ "$output" =~ "auto-detected source repo" ]]; then
    printf 'unexpected auto-detect from a non-git dir\n%s\n' "$output" >&2
    false
  fi
  [[ "$output" =~ "REPO=$fake" ]]
}

@test "auto-detect: rejects a git repo that does not look like ours" {
  # Git repo, but no .dotfiles/scripts/os-detect.sh -- shouldn't be picked up.
  random=$SANDBOX/unrelated-project
  mkdir -p "$random/.dotfiles"
  ( cd "$random" \
      && git init -q \
      && git config user.email t@t \
      && git config user.name t )
  cp "$DOTFILES_REPO_ROOT/install.sh" "$random/.dotfiles/install.sh"
  ( cd "$random" && git add -A && git commit -q -m init )
  # No .dotfiles/scripts/os-detect.sh -- should not be auto-detected.

  # Set DOTFILES_REPO_URL to a real clonable repo for the fallback.
  fake=$SANDBOX/clonable
  _make_fake_our_repo "$fake"
  export DOTFILES_REPO_URL=$fake

  run sh "$random/.dotfiles/install.sh" --on-conflict backup --remove-source no
  [ "$status" -eq 0 ]
  if [[ "$output" =~ "auto-detected source repo" ]]; then
    printf 'falsely auto-detected a non-our repo\n%s\n' "$output" >&2
    false
  fi
  [[ "$output" =~ "REPO=$fake" ]]
}

# --- local --repo + --remove-source ---------------------------------------

@test "invalid --remove-source exits 2" {
  run sh "$INSTALL" --remove-source bogus
  [ "$status" -eq 2 ]
  [[ "$output" =~ "--remove-source must be" ]]
}

@test "--remove-source no leaves the local source clone intact" {
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo
  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict backup \
    --remove-source no
  [ "$status" -eq 0 ]
  [ -d "$SRC_REPO" ]
}

@test "--remove-source yes deletes the local source clone after install" {
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo
  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict backup \
    --remove-source yes
  [ "$status" -eq 0 ]
  [ ! -d "$SRC_REPO" ]
  [[ "$output" =~ "removed $SRC_REPO" ]]
}

@test "non-interactive default keeps the source clone and prints a hint" {
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo
  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict backup
  [ "$status" -eq 0 ]
  [ -d "$SRC_REPO" ]
  [[ "$output" =~ "non-interactive" ]]
  [[ "$output" =~ "rm -rf $SRC_REPO" ]]
}

@test "local source with origin: bare repo's origin gets rewired" {
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo
  # Add a fake remote origin to the source clone.
  ( cd "$SRC_REPO" && git remote add origin https://github.com/u/r.git )
  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict backup \
    --remove-source no
  [ "$status" -eq 0 ]
  # Confirm the bare repo's origin is the rewired URL, not the local path.
  run git --git-dir="$HOME/.config.git" remote get-url origin
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/u/r.git" ]
}

@test "remote --repo URL: --remove-source is a no-op (no removal attempted)" {
  # Use the local source repo, but pass it WITHOUT being a directory
  # check — simulate a URL by giving it a non-existent path string
  # that nonetheless gets clone-skipped because we pre-create DOT_DIR.
  # Simpler approach: pass a real local repo with --remove-source no
  # and make sure no cleanup chatter appears under a "remote"-style
  # invocation. (Full remote URL test would need network; skip that.)
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo

  # Pre-clone so install.sh skips the clone step entirely.
  git clone -q --bare "$SRC_REPO" "$HOME/.config.git"
  # Now run install with a fake URL string that isn't a local dir;
  # the cleanup block should not trigger (LOCAL_SOURCE stays empty).
  run sh "$INSTALL" --repo "https://example.invalid/u/r.git" \
    --on-conflict backup --remove-source ask
  [ "$status" -eq 0 ]
  if [[ "$output" =~ "source clone at" ]]; then
    printf 'unexpected source-clone cleanup chatter:\n%s\n' "$output" >&2
    false
  fi
}

@test "re-running install on an already-installed machine is safe" {
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo

  sh "$INSTALL" --repo "$SRC_REPO" --on-conflict backup >/dev/null
  # Second run: nothing changed, should be no conflicts.
  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict abort
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no conflicts" ]]
}

@test "re-run leaves all tracked files present (identical-files regression)" {
  # Regression: on re-run, identical files were removed then `dot checkout`
  # (no args) did not restore them because git treats no-arg checkout as a
  # branch switch (no-op when already current), not a work-tree restore.
  # Fix: use `( cd "$HOME" && dot checkout HEAD -- . )` which always restores
  # missing files regardless of cwd.
  make_src_repo
  add_to_repo .bashrc "# bashrc"
  add_to_repo .config/shell/aliases.sh "# aliases"
  publish_repo

  sh "$INSTALL" --repo "$SRC_REPO" --on-conflict backup >/dev/null
  [ -f "$HOME/.bashrc" ]
  [ -f "$HOME/.config/shell/aliases.sh" ]

  # Second run with all files identical — they must still be present afterward.
  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict abort
  [ "$status" -eq 0 ]
  [ -f "$HOME/.bashrc" ]
  [ -f "$HOME/.config/shell/aliases.sh" ]
  grep -q "# bashrc" "$HOME/.bashrc"
}

# --- --age-key flag ----------------------------------------------------------

@test "--age-key installs key to XDG_CONFIG_HOME/sops/age/keys.txt" {
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo

  key_file="$SANDBOX/keys.txt"
  printf '# created: 2024-01-01\nAGE-SECRET-KEY-1FAKE\n' > "$key_file"

  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict backup --age-key "$key_file"
  [ "$status" -eq 0 ]
  [ -f "$XDG_CONFIG_HOME/sops/age/keys.txt" ]
  grep -q "AGE-SECRET-KEY-1FAKE" "$XDG_CONFIG_HOME/sops/age/keys.txt"
  [[ "$output" =~ "installed age key from" ]]
}

@test "--age-key result file has mode 0600" {
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo

  key_file="$SANDBOX/keys.txt"
  printf 'AGE-SECRET-KEY-1FAKE\n' > "$key_file"

  sh "$INSTALL" --repo "$SRC_REPO" --on-conflict backup --age-key "$key_file" >/dev/null
  perms=$(stat -c '%a' "$XDG_CONFIG_HOME/sops/age/keys.txt")
  [ "$perms" = "600" ]
}

@test "--age-key with unreadable path warns and install still succeeds" {
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo

  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict backup \
    --age-key "$SANDBOX/nonexistent-keys.txt"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "warn:" ]]
  [ ! -f "$XDG_CONFIG_HOME/sops/age/keys.txt" ]
}

@test "--age-key does not overwrite an existing key" {
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo

  mkdir -p "$XDG_CONFIG_HOME/sops/age"
  printf 'AGE-SECRET-KEY-1EXISTING\n' > "$XDG_CONFIG_HOME/sops/age/keys.txt"
  chmod 0600 "$XDG_CONFIG_HOME/sops/age/keys.txt"

  new_key="$SANDBOX/new-keys.txt"
  printf 'AGE-SECRET-KEY-1NEW\n' > "$new_key"

  run sh "$INSTALL" --repo "$SRC_REPO" --on-conflict backup --age-key "$new_key"
  [ "$status" -eq 0 ]
  grep -q "AGE-SECRET-KEY-1EXISTING" "$XDG_CONFIG_HOME/sops/age/keys.txt"
}

# --- re-run tests (existing) -------------------------------------------------

@test "re-run works when invoked from a subdirectory of HOME" {
  # Regression: `dot checkout HEAD -- .` resolves '.' relative to cwd.
  # When invoked from e.g. ~/dotfiles, no tracked files live there, so git
  # errors with "pathspec '.' did not match any file(s) known to git".
  # Fix: wrap in ( cd "$HOME" && ... ) so '.' always means the work-tree root.
  make_src_repo
  add_to_repo .bashrc "# bashrc"
  publish_repo

  sh "$INSTALL" --repo "$SRC_REPO" --on-conflict backup >/dev/null

  # Run install from a subdirectory of HOME, not from HOME itself.
  subdir="$HOME/some-project"
  mkdir -p "$subdir"
  run sh -c "cd '$subdir' && sh '$INSTALL' --repo '$SRC_REPO' --on-conflict abort"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.bashrc" ]
}
