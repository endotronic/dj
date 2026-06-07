#!/usr/bin/env bats
#
# Tests for install.sh. Two repos get bootstrapped:
#   ~/.dotfiles/    public tooling repo -- normal `git clone` (or used
#                   in place when install.sh already lives in one)
#   ~/.config.git/  private bare repo, work-tree $HOME -- personal
#                   config + secrets, optionally cloned from
#                   --private-repo, else initialized empty
#
# The big-ticket coverage on the private-repo side is conflict
# detection: identical files aren't conflicts, differing files are,
# and the three --on-conflict modes (backup / keep / abort) leave the
# right end state.

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

# Stage a minimal "our repo" checkout at $HOME/.dotfiles so install.sh
# uses it in place (no clone needed). Use whenever the test cares
# about the private-repo flow but not about how the public tooling
# repo got there.
stage_fake_dotfiles_checkout() {
  mkdir -p "$HOME/.dotfiles/scripts"
  cp "$DOTFILES_REPO_ROOT/install.sh"           "$HOME/.dotfiles/install.sh"
  cp "$DOTFILES_REPO_ROOT/scripts/os-detect.sh" "$HOME/.dotfiles/scripts/os-detect.sh"
}

# Build a fake "our repo" (public-tooling shape: install.sh +
# scripts/os-detect.sh at the toplevel) at $1, with a marker file
# whose content is $2, committed so it's clonable.
_make_fake_repo_dir() {
  local where=$1 marker=$2
  mkdir -p "$where/scripts"
  cp "$DOTFILES_REPO_ROOT/install.sh"           "$where/install.sh"
  cp "$DOTFILES_REPO_ROOT/scripts/os-detect.sh" "$where/scripts/os-detect.sh"
  printf '%s\n' "$marker" > "$where/MARKER"
  ( cd "$where" \
      && git init -q \
      && git config user.email t@t \
      && git config user.name t \
      && git config commit.gpgsign false \
      && git add -A \
      && git commit -q -m init )
}

# --- argument validation --------------------------------------------------

@test "--help exits 0 and prints usage" {
  run sh "$INSTALL" --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ Usage ]]
  [[ "$output" =~ "--system-type" ]]
  [[ "$output" =~ "--on-conflict" ]]
  [[ "$output" =~ "--age-key" ]]
  [[ "$output" =~ "--private-repo" ]]
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

# --- public repo: existing checkout vs. fresh clone -----------------------

@test "existing ~/.dotfiles checkout is used in place (no clone)" {
  stage_fake_dotfiles_checkout

  run sh "$INSTALL" --on-conflict backup --remove-source no
  [ "$status" -eq 0 ]
  [[ "$output" =~ "using existing checkout at $HOME/.dotfiles" ]]
}

@test "no existing ~/.dotfiles: --repo local dir gets cloned there" {
  fake=$SANDBOX/src-public-repo
  _make_fake_repo_dir "$fake" "marker content"

  run sh "$INSTALL" --repo "$fake" --on-conflict backup --remove-source no
  [ "$status" -eq 0 ]
  [[ "$output" =~ "cloning $fake into $HOME/.dotfiles" ]]
  [ -f "$HOME/.dotfiles/MARKER" ]
  grep -q "marker content" "$HOME/.dotfiles/MARKER"
}

# --- private repo: empty-init fallback and cloning -------------------------

@test "no --private-repo: initializes an empty bare private repo" {
  stage_fake_dotfiles_checkout

  run sh "$INSTALL" --on-conflict backup
  [ "$status" -eq 0 ]
  [[ "$output" =~ "initializing empty private repo" ]]
  [ -d "$HOME/.config.git" ]
  run dot rev-parse --verify -q HEAD
  [ "$status" -ne 0 ]
}

@test "--private-repo clones a local repo and checks it out" {
  stage_fake_dotfiles_checkout
  make_src_repo
  add_to_repo .bashrc "# private tracked"
  publish_repo

  run sh "$INSTALL" --private-repo "$SRC_REPO" --on-conflict backup
  [ "$status" -eq 0 ]
  [[ "$output" =~ "cloned private repo" ]]
  [ -f "$HOME/.bashrc" ]
  grep -q "private tracked" "$HOME/.bashrc"
}

@test "--private-repo with unreachable source falls back to empty init" {
  stage_fake_dotfiles_checkout

  run sh "$INSTALL" --private-repo "$SANDBOX/does-not-exist.git" --on-conflict backup
  [ "$status" -eq 0 ]
  [[ "$output" =~ "warn: clone of private repo failed" ]]
  [[ "$output" =~ "initializing empty private repo" ]]
  [ -d "$HOME/.config.git" ]
}

@test "--private-repo http(s) URL in non-interactive shell skips clone, inits empty" {
  stage_fake_dotfiles_checkout

  run sh "$INSTALL" --private-repo "https://example.invalid/u/private.git" --on-conflict backup
  [ "$status" -eq 0 ]
  [[ "$output" =~ "cannot prompt for git credentials" ]]
  [[ "$output" =~ "initializing empty private repo" ]]
  [ -d "$HOME/.config.git" ]
}

@test "existing private repo is used in place (no re-clone)" {
  stage_fake_dotfiles_checkout
  make_src_repo
  add_to_repo .bashrc "# private tracked"
  publish_repo

  sh "$INSTALL" --private-repo "$SRC_REPO" --on-conflict backup >/dev/null
  run sh "$INSTALL" --private-repo "$SRC_REPO" --on-conflict backup
  [ "$status" -eq 0 ]
  [[ "$output" =~ "using existing private repo at $HOME/.config.git" ]]
}

# --- fresh checkout into empty $HOME (private repo) -----------------------

@test "fresh install checks out tracked private-repo files into HOME" {
  stage_fake_dotfiles_checkout
  make_src_repo
  add_to_repo .bashrc "# tracked bashrc"
  add_to_repo .config/foo.toml "key = 1"
  publish_repo

  run sh "$INSTALL" --private-repo "$SRC_REPO" --on-conflict backup
  [ "$status" -eq 0 ]
  [ -d "$HOME/.config.git" ]
  [ -f "$HOME/.bashrc" ]
  [ -f "$HOME/.config/foo.toml" ]
  grep -q "tracked bashrc" "$HOME/.bashrc"
}

@test "fresh install reports 'no conflicts' when HOME is empty" {
  stage_fake_dotfiles_checkout
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo
  run sh "$INSTALL" --private-repo "$SRC_REPO" --on-conflict abort
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no conflicts" ]]
}

# --- conflict detection ----------------------------------------------------

@test "identical-content files are NOT conflicts" {
  stage_fake_dotfiles_checkout
  make_src_repo
  add_to_repo .bashrc "# same on both sides"
  publish_repo
  # Pre-populate $HOME with the EXACT same content.
  printf '%s\n' "# same on both sides" > "$HOME/.bashrc"

  run sh "$INSTALL" --private-repo "$SRC_REPO" --on-conflict abort
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no conflicts" ]]
  # File unchanged.
  grep -q "same on both sides" "$HOME/.bashrc"
}

@test "differing files ARE conflicts" {
  stage_fake_dotfiles_checkout
  make_src_repo
  add_to_repo .bashrc "# tracked version"
  publish_repo
  printf '%s\n' "# DIFFERENT user version" > "$HOME/.bashrc"

  run sh "$INSTALL" --private-repo "$SRC_REPO" --on-conflict abort
  [ "$status" -eq 1 ]
  [[ "$output" =~ ".bashrc" ]]
}

@test "symlinks in HOME are skipped (not flagged as conflicts)" {
  stage_fake_dotfiles_checkout
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo
  # User has a symlink at .bashrc pointing elsewhere.
  printf 'other\n' > "$HOME/.other-bashrc"
  ln -s "$HOME/.other-bashrc" "$HOME/.bashrc"

  run sh "$INSTALL" --private-repo "$SRC_REPO" --on-conflict abort
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no conflicts" ]]
}

# --- --on-conflict backup -------------------------------------------------

@test "--on-conflict backup moves originals and writes tracked versions" {
  stage_fake_dotfiles_checkout
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo
  printf '%s\n' "# user" > "$HOME/.bashrc"

  run sh "$INSTALL" --private-repo "$SRC_REPO" --on-conflict backup
  [ "$status" -eq 0 ]
  grep -q "^# tracked" "$HOME/.bashrc"
  # The user version is preserved in the backup tree.
  found=$(find "$HOME/.dotfiles-backup" -name .bashrc -type f | head -1)
  [ -n "$found" ]
  grep -q "^# user" "$found"
}

# --- --on-conflict keep ---------------------------------------------------

@test "--on-conflict keep preserves user version; backup has user copy too" {
  stage_fake_dotfiles_checkout
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo
  printf '%s\n' "# user" > "$HOME/.bashrc"

  run sh "$INSTALL" --private-repo "$SRC_REPO" --on-conflict keep
  [ "$status" -eq 0 ]
  # User version still in place.
  grep -q "^# user" "$HOME/.bashrc"
  # Backup also has the user version (the moved-aside copy).
  found=$(find "$HOME/.dotfiles-backup" -name .bashrc -type f | head -1)
  [ -n "$found" ]
  grep -q "^# user" "$found"
}

@test "--on-conflict keep leaves the file as modified per dot status" {
  stage_fake_dotfiles_checkout
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo
  printf '%s\n' "# user" > "$HOME/.bashrc"

  run sh "$INSTALL" --private-repo "$SRC_REPO" --on-conflict keep
  [ "$status" -eq 0 ]
  # `dot status` should report .bashrc as modified.
  run dot status --porcelain
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[[:space:]]?M[[:space:]].bashrc ]] || \
    [[ "$output" =~ M\ .bashrc ]]
}

# --- --on-conflict abort --------------------------------------------------

@test "--on-conflict abort exits 1 and leaves HOME untouched" {
  stage_fake_dotfiles_checkout
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo
  printf '%s\n' "# user" > "$HOME/.bashrc"

  run sh "$INSTALL" --private-repo "$SRC_REPO" --on-conflict abort
  [ "$status" -eq 1 ]
  grep -q "^# user" "$HOME/.bashrc"
  [ ! -d "$HOME/.dotfiles-backup" ]
}

# --- non-interactive guard -------------------------------------------------

@test "--on-conflict ask refuses to act when non-interactive and conflicts exist" {
  stage_fake_dotfiles_checkout
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo
  printf '%s\n' "# user" > "$HOME/.bashrc"

  # `run` gives no controlling TTY, so this exercises the
  # non-interactive guard.
  run sh "$INSTALL" --private-repo "$SRC_REPO" --on-conflict ask
  [ "$status" -eq 1 ]
  [[ "$output" =~ "non-interactive" ]]
  # HOME unchanged.
  grep -q "^# user" "$HOME/.bashrc"
}

# --- system-type persistence ---------------------------------------------

@test "--system-type desktop writes the tier file" {
  stage_fake_dotfiles_checkout
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo

  run sh "$INSTALL" --private-repo "$SRC_REPO" --system-type desktop --on-conflict backup
  [ "$status" -eq 0 ]
  [ -f "$XDG_CONFIG_HOME/dotfiles/system-type" ]
  [ "$(cat "$XDG_CONFIG_HOME/dotfiles/system-type")" = "desktop" ]
}

@test "re-running without --system-type preserves the previous tier" {
  stage_fake_dotfiles_checkout
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo

  sh "$INSTALL" --private-repo "$SRC_REPO" --system-type server --on-conflict backup >/dev/null
  # Re-run without the flag.
  run sh "$INSTALL" --private-repo "$SRC_REPO" --on-conflict backup
  [ "$status" -eq 0 ]
  [ "$(cat "$XDG_CONFIG_HOME/dotfiles/system-type")" = "server" ]
}

# --- auto-detection of public-repo source (when --repo not given) ---------

@test "auto-detect: install.sh inside its own clone uses that clone as default" {
  fake=$SANDBOX/fake-our-repo
  _make_fake_repo_dir "$fake" "fake marker"

  run sh "$fake/install.sh" --on-conflict backup --remove-source no
  [ "$status" -eq 0 ]
  [[ "$output" =~ "auto-detected source repo: $fake" ]]
  [[ "$output" =~ "REPO=$fake" ]]
  [ -f "$HOME/.dotfiles/MARKER" ]
  grep -q "fake marker" "$HOME/.dotfiles/MARKER"
}

@test "auto-detect: --repo takes priority over auto-detection" {
  fake=$SANDBOX/fake-our-repo
  _make_fake_repo_dir "$fake" "fake marker"
  other=$SANDBOX/other-repo
  _make_fake_repo_dir "$other" "OTHER marker"

  run sh "$fake/install.sh" --repo "$other" \
    --on-conflict backup --remove-source no
  [ "$status" -eq 0 ]
  # Should NOT auto-detect, REPO is the --repo path.
  if [[ "$output" =~ "auto-detected source repo" ]]; then
    printf 'unexpected auto-detect when --repo was explicit\n%s\n' "$output" >&2
    false
  fi
  [[ "$output" =~ "REPO=$other" ]]
  grep -q "OTHER marker" "$HOME/.dotfiles/MARKER"
}

@test "auto-detect: script outside any git repo falls back to default URL" {
  # Place install.sh in a location not under any git dir.
  outside=$SANDBOX/free-standing
  mkdir -p "$outside/scripts"
  cp "$DOTFILES_REPO_ROOT/install.sh"           "$outside/install.sh"
  cp "$DOTFILES_REPO_ROOT/scripts/os-detect.sh" "$outside/scripts/os-detect.sh"
  # NO git init -- this dir is not a repo.

  # Have to give DOTFILES_REPO_URL so the fallback resolves to
  # something cloneable for the test.
  fake=$SANDBOX/clonable
  _make_fake_repo_dir "$fake" "clonable marker"
  export DOTFILES_REPO_URL=$fake

  run sh "$outside/install.sh" --on-conflict backup --remove-source no
  [ "$status" -eq 0 ]
  if [[ "$output" =~ "auto-detected source repo" ]]; then
    printf 'unexpected auto-detect from a non-git dir\n%s\n' "$output" >&2
    false
  fi
  [[ "$output" =~ "REPO=$fake" ]]
  grep -q "clonable marker" "$HOME/.dotfiles/MARKER"
}

@test "auto-detect: rejects a git repo that does not look like ours" {
  # Git repo containing install.sh but missing scripts/os-detect.sh --
  # shouldn't be picked up as "our repo".
  random=$SANDBOX/unrelated-project
  mkdir -p "$random"
  cp "$DOTFILES_REPO_ROOT/install.sh" "$random/install.sh"
  ( cd "$random" \
      && git init -q \
      && git config user.email t@t \
      && git config user.name t \
      && git config commit.gpgsign false \
      && git add -A \
      && git commit -q -m init )

  fake=$SANDBOX/clonable
  _make_fake_repo_dir "$fake" "clonable marker"
  export DOTFILES_REPO_URL=$fake

  run sh "$random/install.sh" --on-conflict backup --remove-source no
  [ "$status" -eq 0 ]
  if [[ "$output" =~ "auto-detected source repo" ]]; then
    printf 'falsely auto-detected a non-our repo\n%s\n' "$output" >&2
    false
  fi
  [[ "$output" =~ "REPO=$fake" ]]
}

# --- local --repo + --remove-source (public repo) -------------------------

@test "invalid --remove-source exits 2" {
  run sh "$INSTALL" --remove-source bogus
  [ "$status" -eq 2 ]
  [[ "$output" =~ "--remove-source must be" ]]
}

@test "--remove-source no leaves the local source clone intact" {
  fake=$SANDBOX/src-public-repo
  _make_fake_repo_dir "$fake" "marker"
  run sh "$INSTALL" --repo "$fake" --on-conflict backup --remove-source no
  [ "$status" -eq 0 ]
  [ -d "$fake" ]
}

@test "--remove-source yes deletes the local source clone after install" {
  fake=$SANDBOX/src-public-repo
  _make_fake_repo_dir "$fake" "marker"
  run sh "$INSTALL" --repo "$fake" --on-conflict backup --remove-source yes
  [ "$status" -eq 0 ]
  [ ! -d "$fake" ]
  [[ "$output" =~ "removed $fake" ]]
}

@test "non-interactive default keeps the source clone and prints a hint" {
  fake=$SANDBOX/src-public-repo
  _make_fake_repo_dir "$fake" "marker"
  run sh "$INSTALL" --repo "$fake" --on-conflict backup
  [ "$status" -eq 0 ]
  [ -d "$fake" ]
  [[ "$output" =~ "non-interactive" ]]
  [[ "$output" =~ "rm -rf $fake" ]]
}

@test "local source with origin: cloned public repo's origin gets rewired" {
  fake=$SANDBOX/src-public-repo
  _make_fake_repo_dir "$fake" "marker"
  ( cd "$fake" && git remote add origin https://github.com/u/r.git )
  run sh "$INSTALL" --repo "$fake" --on-conflict backup --remove-source no
  [ "$status" -eq 0 ]
  run git -C "$HOME/.dotfiles" remote get-url origin
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/u/r.git" ]
}

@test "remote --repo URL with existing checkout: --remove-source is a no-op" {
  stage_fake_dotfiles_checkout
  run sh "$INSTALL" --repo "https://example.invalid/u/r.git" \
    --on-conflict backup --remove-source ask
  [ "$status" -eq 0 ]
  if [[ "$output" =~ "source clone at" ]]; then
    printf 'unexpected source-clone cleanup chatter:\n%s\n' "$output" >&2
    false
  fi
}

# --- idempotency ---------------------------------------------------------

@test "re-running install on an already-installed machine is safe" {
  stage_fake_dotfiles_checkout
  make_src_repo
  add_to_repo .bashrc "# tracked"
  publish_repo

  sh "$INSTALL" --private-repo "$SRC_REPO" --on-conflict backup >/dev/null
  # Second run: nothing changed, should be no conflicts.
  run sh "$INSTALL" --private-repo "$SRC_REPO" --on-conflict abort
  [ "$status" -eq 0 ]
  [[ "$output" =~ "no conflicts" ]]
}

@test "re-run leaves all tracked files present (identical-files regression)" {
  # Regression: on re-run, identical files were removed then `dot checkout`
  # (no args) did not restore them because git treats no-arg checkout as a
  # branch switch (no-op when already current), not a work-tree restore.
  # Fix: use `( cd "$HOME" && dot checkout HEAD -- . )` which always restores
  # missing files regardless of cwd.
  stage_fake_dotfiles_checkout
  make_src_repo
  add_to_repo .bashrc "# bashrc"
  add_to_repo .config/shell/aliases.sh "# aliases"
  publish_repo

  sh "$INSTALL" --private-repo "$SRC_REPO" --on-conflict backup >/dev/null
  [ -f "$HOME/.bashrc" ]
  [ -f "$HOME/.config/shell/aliases.sh" ]

  # Second run with all files identical — they must still be present afterward.
  run sh "$INSTALL" --private-repo "$SRC_REPO" --on-conflict abort
  [ "$status" -eq 0 ]
  [ -f "$HOME/.bashrc" ]
  [ -f "$HOME/.config/shell/aliases.sh" ]
  grep -q "# bashrc" "$HOME/.bashrc"
}

# --- --age-key flag ----------------------------------------------------------

@test "--age-key installs key to XDG_CONFIG_HOME/sops/age/keys.txt" {
  stage_fake_dotfiles_checkout

  key_file="$SANDBOX/keys.txt"
  printf '# created: 2024-01-01\nAGE-SECRET-KEY-1FAKE\n' > "$key_file"

  run sh "$INSTALL" --on-conflict backup --age-key "$key_file"
  [ "$status" -eq 0 ]
  [ -f "$XDG_CONFIG_HOME/sops/age/keys.txt" ]
  grep -q "AGE-SECRET-KEY-1FAKE" "$XDG_CONFIG_HOME/sops/age/keys.txt"
  [[ "$output" =~ "installed age key from" ]]
}

@test "--age-key result file has mode 0600" {
  stage_fake_dotfiles_checkout

  key_file="$SANDBOX/keys.txt"
  printf 'AGE-SECRET-KEY-1FAKE\n' > "$key_file"

  sh "$INSTALL" --on-conflict backup --age-key "$key_file" >/dev/null
  perms=$(stat -c '%a' "$XDG_CONFIG_HOME/sops/age/keys.txt")
  [ "$perms" = "600" ]
}

@test "--age-key with unreadable path warns and install still succeeds" {
  stage_fake_dotfiles_checkout

  run sh "$INSTALL" --on-conflict backup \
    --age-key "$SANDBOX/nonexistent-keys.txt"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "warn:" ]]
  [ ! -f "$XDG_CONFIG_HOME/sops/age/keys.txt" ]
}

@test "--age-key does not overwrite an existing key" {
  stage_fake_dotfiles_checkout

  mkdir -p "$XDG_CONFIG_HOME/sops/age"
  printf 'AGE-SECRET-KEY-1EXISTING\n' > "$XDG_CONFIG_HOME/sops/age/keys.txt"
  chmod 0600 "$XDG_CONFIG_HOME/sops/age/keys.txt"

  new_key="$SANDBOX/new-keys.txt"
  printf 'AGE-SECRET-KEY-1NEW\n' > "$new_key"

  run sh "$INSTALL" --on-conflict backup --age-key "$new_key"
  [ "$status" -eq 0 ]
  grep -q "AGE-SECRET-KEY-1EXISTING" "$XDG_CONFIG_HOME/sops/age/keys.txt"
}

# --- re-run tests (existing) -------------------------------------------------

@test "re-run works when invoked from a subdirectory of HOME" {
  # Regression: `dot checkout HEAD -- .` resolves '.' relative to cwd.
  # When invoked from e.g. ~/dotfiles, no tracked files live there, so git
  # errors with "pathspec '.' did not match any file(s) known to git".
  # Fix: wrap in ( cd "$HOME" && ... ) so '.' always means the work-tree root.
  stage_fake_dotfiles_checkout
  make_src_repo
  add_to_repo .bashrc "# bashrc"
  publish_repo

  sh "$INSTALL" --private-repo "$SRC_REPO" --on-conflict backup >/dev/null

  # Run install from a subdirectory of HOME, not from HOME itself.
  subdir="$HOME/some-project"
  mkdir -p "$subdir"
  run sh -c "cd '$subdir' && sh '$INSTALL' --private-repo '$SRC_REPO' --on-conflict abort"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.bashrc" ]
}
