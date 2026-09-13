#!/usr/bin/env bats
#
# Tests for scripts/authorized-keys.sh: registers this machine's own
# public key as ~/.ssh/authorized_keys.d/<host>.pub and rebuilds
# ~/.ssh/authorized_keys from every .pub in that directory.
#
# The safety properties matter more than the happy path here: an empty
# key directory must NOT truncate an existing authorized_keys, and a
# key present in authorized_keys but not in the directory must not be
# silently revoked without a backup.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  export SCRIPT="$DOTFILES_REPO_ROOT/scripts/authorized-keys.sh"
  export DOT_DIR="$HOME/.config.git"
  mkdir -p "$HOME/.ssh"
  export HOSTNAME_SHORT="$(hostname -s 2>/dev/null || uname -n)"
}

teardown() {
  sandbox_teardown
}

make_pubkey() {
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5%s %s\n' "$1" "$2"
}

# --- registering this machine ------------------------------------------

@test "registers this machine's pubkey into authorized_keys.d" {
  make_pubkey MINE kevin@here > "$HOME/.ssh/id_ed25519.pub"

  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.ssh/authorized_keys.d/$HOSTNAME_SHORT.pub" ]
  grep -q "AAAAC3NzaC1lZDI1NTE5MINE" "$HOME/.ssh/authorized_keys.d/$HOSTNAME_SHORT.pub"
}

@test "re-running is idempotent and reports already-registered" {
  make_pubkey MINE kevin@here > "$HOME/.ssh/id_ed25519.pub"
  sh "$SCRIPT" >/dev/null

  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already registered" ]]
}

@test "--no-register rebuilds without adding this machine's key" {
  make_pubkey MINE kevin@here > "$HOME/.ssh/id_ed25519.pub"
  mkdir -p "$HOME/.ssh/authorized_keys.d"
  make_pubkey OTHER kevin@other > "$HOME/.ssh/authorized_keys.d/other.pub"

  run sh "$SCRIPT" --no-register
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.ssh/authorized_keys.d/$HOSTNAME_SHORT.pub" ]
  grep -q "AAAAC3NzaC1lZDI1NTE5OTHER" "$HOME/.ssh/authorized_keys"
}

@test "missing pubkey is not fatal" {
  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "nothing of our own to register" ]]
}

# --- rebuilding authorized_keys ----------------------------------------

@test "authorized_keys is the union of every .pub in the directory" {
  mkdir -p "$HOME/.ssh/authorized_keys.d"
  make_pubkey AAA kevin@alpha > "$HOME/.ssh/authorized_keys.d/alpha.pub"
  make_pubkey BBB kevin@beta  > "$HOME/.ssh/authorized_keys.d/beta.pub"

  run sh "$SCRIPT" --no-register
  [ "$status" -eq 0 ]
  grep -q "AAAAC3NzaC1lZDI1NTE5AAA" "$HOME/.ssh/authorized_keys"
  grep -q "AAAAC3NzaC1lZDI1NTE5BBB" "$HOME/.ssh/authorized_keys"
}

@test "rebuilt authorized_keys has mode 0600 and .ssh stays 0700" {
  mkdir -p "$HOME/.ssh/authorized_keys.d"
  make_pubkey AAA kevin@alpha > "$HOME/.ssh/authorized_keys.d/alpha.pub"

  sh "$SCRIPT" --no-register >/dev/null
  [ "$(stat -c '%a' "$HOME/.ssh/authorized_keys")" = "600" ]
  [ "$(stat -c '%a' "$HOME/.ssh")" = "700" ]
}

@test "an empty key directory never truncates an existing authorized_keys" {
  # Regression guard: rebuilding from nothing must not lock out every
  # machine that can currently reach this one.
  printf 'ssh-ed25519 AAAAPRECIOUS kevin@elsewhere\n' > "$HOME/.ssh/authorized_keys"

  run sh "$SCRIPT" --no-register
  [ "$status" -eq 0 ]
  [[ "$output" =~ "leaving" ]]
  grep -q "AAAAPRECIOUS" "$HOME/.ssh/authorized_keys"
}

@test "a key only in authorized_keys is backed up before being dropped" {
  printf 'ssh-ed25519 AAAAHANDADDED kevin@manual\n' > "$HOME/.ssh/authorized_keys"
  mkdir -p "$HOME/.ssh/authorized_keys.d"
  make_pubkey AAA kevin@alpha > "$HOME/.ssh/authorized_keys.d/alpha.pub"
  export BACKUP_DIR="$SANDBOX/backup"

  run sh "$SCRIPT" --no-register
  [ "$status" -eq 0 ]
  [[ "$output" =~ "aren't in" ]]
  grep -q "AAAAHANDADDED" "$SANDBOX/backup/.ssh/authorized_keys"
  # And the rebuilt file is the directory's content only.
  grep -q "AAAAC3NzaC1lZDI1NTE5AAA" "$HOME/.ssh/authorized_keys"
  ! grep -q "AAAAHANDADDED" "$HOME/.ssh/authorized_keys"
}

@test "a key present in both is not treated as an orphan" {
  mkdir -p "$HOME/.ssh/authorized_keys.d"
  make_pubkey AAA kevin@alpha > "$HOME/.ssh/authorized_keys.d/alpha.pub"
  sh "$SCRIPT" --no-register >/dev/null

  run sh "$SCRIPT" --no-register
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "aren't in" ]]
  [[ "$output" =~ "already up to date" ]]
}

@test "unknown argument exits 2" {
  run sh "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" =~ "unknown argument" ]]
}

# --- staging into the private repo -------------------------------------

@test "a newly registered key is staged and committed in the private repo, but not pushed" {
  make_pubkey MINE kevin@here > "$HOME/.ssh/id_ed25519.pub"
  git init --bare -q "$DOT_DIR"
  git --git-dir="$DOT_DIR" --work-tree="$HOME" config user.email t@t
  git --git-dir="$DOT_DIR" --work-tree="$HOME" config user.name t
  git --git-dir="$DOT_DIR" --work-tree="$HOME" config commit.gpgsign false

  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "committed" ]]
  # Nothing left staged -- it was committed, not just added.
  run git --git-dir="$DOT_DIR" --work-tree="$HOME" diff --cached --name-only
  [ -z "$output" ]
  run git --git-dir="$DOT_DIR" --work-tree="$HOME" log -1 --name-only --pretty=format:%s
  [[ "$output" =~ "Add SSH public key for $HOSTNAME_SHORT" ]]
  [[ "$output" =~ "authorized_keys.d/$HOSTNAME_SHORT.pub" ]]
  # No remote configured, so pushing was never even possible -- but
  # the point is this script doesn't try: confirm no `git push`
  # equivalent left the commit anywhere but the local bare repo's
  # branch tip (i.e. HEAD really did move, nothing more).
  [ "$(git --git-dir="$DOT_DIR" rev-list --count HEAD)" = 1 ]
}

@test "a failed commit (e.g. no git identity configured) still leaves the key staged, with a warning" {
  make_pubkey MINE kevin@here > "$HOME/.ssh/id_ed25519.pub"
  git init --bare -q "$DOT_DIR"
  # Deliberately no user.email/user.name -- git refuses to commit.

  run sh "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "commit it yourself" ]]
  run git --git-dir="$DOT_DIR" --work-tree="$HOME" diff --cached --name-only
  [[ "$output" =~ "authorized_keys.d/$HOSTNAME_SHORT.pub" ]]
}
