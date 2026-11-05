#!/usr/bin/env bats
#
# Coverage for scripts/migrate.sh and the core migrations in migrations/
# -- the detect/repair mechanism for machine state that newer code
# expects but an older bootstrap never created.
#
# Every test points DOTFILES_REPO_ROOT at a throwaway dir inside the
# sandbox, so the migrations that shell out to sibling scripts
# (pending-packages, ...) find nothing and report N/A. That isolates each
# test to the one migration it exercises.

load test_helper

MIGRATE="$DOTFILES_REPO_ROOT/scripts/migrate.sh"

setup() {
  sandbox_setup
  stub_dir_setup
  FAKE_ROOT="$SANDBOX/repo"
  mkdir -p "$FAKE_ROOT/scripts" "$FAKE_ROOT/packages/postinstall"
  export DOTFILES_REPO_ROOT="$FAKE_ROOT"
  export DOT_DIR="$HOME/.config.git"
  export DOTFILES_BACKUP_DIR="$SANDBOX/backup"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
}

teardown() {
  sandbox_teardown
}

# A `bats` whose --version reports the given version string.
stub_bats_version() {
  printf '#!/bin/sh\ncase "$1" in\n  --version) echo "Bats %s" ;;\n  *) exit 0 ;;\nesac\n' \
    "$1" > "$STUB_BIN/bats"
  chmod +x "$STUB_BIN/bats"
}

# Replace PATH with a farm of symlinks to just the binaries migrate.sh
# and the migrations actually call, deliberately omitting `bats`. The
# sandbox only PREPENDS $STUB_BIN, so the host's own bats (the one
# running this suite) is otherwise always reachable and "bats is not
# installed" cannot be expressed.
path_without_bats() {
  local farm="$SANDBOX/minbin" c src
  mkdir -p "$farm"
  for c in sh awk chmod date dirname git grep head hostname id mkdir mktemp mv rm sed ssh-keygen uname; do
    src="$(command -v "$c" 2>/dev/null)" || continue
    [ -n "$src" ] && ln -sf "$src" "$farm/$c"
  done
  export PATH="$STUB_BIN:$farm"
}

# A bare private repo at $DOT_DIR with an origin pointing at a real
# upstream, mimicking what `git clone --bare` leaves behind: no
# remote.origin.fetch, no branch tracking.
make_bare_with_origin() {
  local up="$SANDBOX/upstream"
  git init -q "$up"
  ( cd "$up" && git config user.email t@e.com && git config user.name t \
      && git config commit.gpgsign false \
      && echo hi > f && git add f && git commit -q -m init )
  git clone -q --bare "$up" "$DOT_DIR"
  # a bare clone DOES get a fetch refspec from `git clone`; strip it so
  # we reproduce the state install.sh's own `git clone --bare` leaves.
  git --git-dir="$DOT_DIR" config --unset-all remote.origin.fetch 2>/dev/null || true
  git --git-dir="$DOT_DIR" config --unset branch.master.remote 2>/dev/null || true
  git --git-dir="$DOT_DIR" config --unset branch.master.merge 2>/dev/null || true
  git --git-dir="$DOT_DIR" for-each-ref --format='%(refname)' refs/remotes \
    | while read -r r; do git --git-dir="$DOT_DIR" update-ref -d "$r"; done
}

# --- argument handling ------------------------------------------------------

@test "migrate: --list names every migration with an auto/manual tag" {
  run sh "$MIGRATE" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"git-refspec"*"auto"* ]]
  [[ "$output" == *"legacy-home-git"*"manual"* ]]
  [[ "$output" == *"nixos-flake-applied"* ]]
}

@test "migrate: --help prints usage without running checks" {
  run sh "$MIGRATE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--fix"* ]]
}

@test "migrate: rejects an unknown argument" {
  run sh "$MIGRATE" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "migrate: a clean machine exits 0 and says so" {
  stub_bats_version 1.11.1
  run sh "$MIGRATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"up to date"* ]]
}

# --- git-refspec ------------------------------------------------------------

@test "git-refspec: N/A when there is no private repo" {
  run sh "$MIGRATE" --only git-refspec
  [ "$status" -eq 0 ]
  [[ "$output" != *"origin/* refs"* ]]
}

@test "git-refspec: N/A when the private repo has no origin" {
  git init --bare -q "$DOT_DIR"
  run sh "$MIGRATE" --only git-refspec
  [ "$status" -eq 0 ]
}

@test "git-refspec: pending when the bare clone has no fetch refspec" {
  make_bare_with_origin
  run sh "$MIGRATE" --only git-refspec
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR"* ]]
  [[ "$output" == *"origin/* refs"* ]]
}

@test "git-refspec: --fix sets the refspec, tracking, and fetches" {
  make_bare_with_origin
  run sh "$MIGRATE" --fix --only git-refspec
  [ "$status" -eq 0 ]
  [ "$(git --git-dir="$DOT_DIR" config --get remote.origin.fetch)" = \
    '+refs/heads/*:refs/remotes/origin/*' ]
  [ "$(git --git-dir="$DOT_DIR" config --get branch.master.remote)" = origin ]
  [ "$(git --git-dir="$DOT_DIR" config --get branch.master.merge)" = refs/heads/master ]
  git --git-dir="$DOT_DIR" rev-parse --verify refs/remotes/origin/master
}

@test "git-refspec: --fix is idempotent and the second run reports ok" {
  make_bare_with_origin
  sh "$MIGRATE" --fix --only git-refspec >/dev/null
  run sh "$MIGRATE" --fix --only git-refspec
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
  [ "$(git --git-dir="$DOT_DIR" config --get-all remote.origin.fetch | wc -l)" -eq 1 ]
}

@test "git-refspec: missing branch tracking alone is enough to be pending" {
  make_bare_with_origin
  git --git-dir="$DOT_DIR" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  run sh "$MIGRATE" --only git-refspec
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR"* ]]
}

# --- ssh-pubkey -------------------------------------------------------------

@test "ssh-pubkey: N/A when there is no private key" {
  run sh "$MIGRATE" --only ssh-pubkey
  [ "$status" -eq 0 ]
  [[ "$output" != *"public key"* ]]
}

@test "ssh-pubkey: --fix derives the public half from the private key" {
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C test@host
  rm -f "$HOME/.ssh/id_ed25519.pub"
  run sh "$MIGRATE" --fix --only ssh-pubkey
  [ "$status" -eq 0 ]
  [ -f "$HOME/.ssh/id_ed25519.pub" ]
  [ "$(stat -c '%a' "$HOME/.ssh/id_ed25519.pub")" = 644 ]
  # the derived key must match the private key it came from
  [ "$(ssh-keygen -lf "$HOME/.ssh/id_ed25519" | awk '{print $2}')" = \
    "$(ssh-keygen -lf "$HOME/.ssh/id_ed25519.pub" | awk '{print $2}')" ]
}

@test "ssh-pubkey: ok when the public key already exists" {
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C test@host
  run sh "$MIGRATE" --only ssh-pubkey
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

# --- ssh-pubkey-match -------------------------------------------------------

# Leave ~/.ssh/<name> holding one key and <name>.pub holding another --
# what a manifest key restored over an older hand-made one looks like.
make_stale_pubkey() {
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/$1" -C current
  ssh-keygen -q -t ed25519 -N '' -f "$SANDBOX/old" -C old
  cp "$SANDBOX/old.pub" "$HOME/.ssh/$1.pub"
}

@test "ssh-pubkey-match: ok when every pair matches" {
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C machine
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/onyx_id_ed25519" -C shared
  run sh "$MIGRATE" --only ssh-pubkey-match
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"*"matches the private key"* ]]
}

@test "ssh-pubkey-match: a private key with no .pub is fine" {
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/onyx_id_ed25519" -C shared
  rm -f "$HOME/.ssh/onyx_id_ed25519.pub"
  run sh "$MIGRATE" --only ssh-pubkey-match
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.ssh/onyx_id_ed25519.pub" ]
}

@test "ssh-pubkey-match: pending when a .pub belongs to a different key" {
  make_stale_pubkey onyx_id_ed25519
  run sh "$MIGRATE" --only ssh-pubkey-match
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR"* ]]
}

@test "ssh-pubkey-match: --fix regenerates the .pub and backs up the stale one" {
  make_stale_pubkey onyx_id_ed25519
  run sh "$MIGRATE" --fix --only ssh-pubkey-match
  [ "$status" -eq 0 ]
  [ "$(ssh-keygen -y -f "$HOME/.ssh/onyx_id_ed25519" | awk '{print $2}')" = \
    "$(awk '{print $2}' "$HOME/.ssh/onyx_id_ed25519.pub")" ]
  [ "$(stat -c '%a' "$HOME/.ssh/onyx_id_ed25519.pub")" = 644 ]
  cmp -s "$SANDBOX/old.pub" "$DOTFILES_BACKUP_DIR/.ssh/onyx_id_ed25519.pub"
  # the matching pair is left alone, and a second run is a no-op
  run sh "$MIGRATE" --fix --only ssh-pubkey-match
  [ "$status" -eq 0 ]
  [[ "$output" != *"regenerated"* ]]
}

@test "ssh-pubkey-match: a differing comment alone is not a mismatch" {
  ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C original
  sed -i 's/original$/renamed by hand/' "$HOME/.ssh/id_ed25519.pub"
  run sh "$MIGRATE" --only ssh-pubkey-match
  [ "$status" -eq 0 ]
}

@test "ssh-pubkey-match: a passphrase-protected key is skipped, not prompted for" {
  ssh-keygen -q -t ed25519 -N 'secret' -f "$HOME/.ssh/id_locked" -C locked
  ssh-keygen -q -t ed25519 -N '' -f "$SANDBOX/old" -C old
  cp "$SANDBOX/old.pub" "$HOME/.ssh/id_locked.pub"
  run sh "$MIGRATE" --only ssh-pubkey-match < /dev/null
  [ "$status" -eq 0 ]
}

# --- legacy-tmux-conf -------------------------------------------------------

@test "legacy-tmux-conf: N/A when no tracked tmux.conf is deployed" {
  : > "$HOME/.tmux.conf"
  run sh "$MIGRATE" --only legacy-tmux-conf
  [ "$status" -eq 0 ]
}

@test "legacy-tmux-conf: --fix moves every ~/.tmux.conf* aside" {
  mkdir -p "$HOME/.config/tmux"
  echo tracked > "$HOME/.config/tmux/tmux.conf"
  echo legacy   > "$HOME/.tmux.conf"
  echo tmpl     > "$HOME/.tmux.conf.template"
  run sh "$MIGRATE" --fix --only legacy-tmux-conf
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.tmux.conf" ]
  [ ! -e "$HOME/.tmux.conf.template" ]
  [ "$(cat "$DOTFILES_BACKUP_DIR/.tmux.conf")" = legacy ]
  [ "$(cat "$DOTFILES_BACKUP_DIR/.tmux.conf.template")" = tmpl ]
  # the tracked config is untouched
  [ "$(cat "$HOME/.config/tmux/tmux.conf")" = tracked ]
}

@test "legacy-tmux-conf: ok once nothing shadows the tracked config" {
  mkdir -p "$HOME/.config/tmux"
  : > "$HOME/.config/tmux/tmux.conf"
  run sh "$MIGRATE" --only legacy-tmux-conf
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

# --- bats-version -----------------------------------------------------------

@test "bats-version: N/A when bats is not installed" {
  path_without_bats
  run sh "$MIGRATE" --only bats-version
  [ "$status" -eq 0 ]
  [[ "$output" != *"test suite"* ]]
}

@test "bats-version: ok at exactly the 1.5 minimum" {
  stub_bats_version 1.5.0
  run sh "$MIGRATE" --only bats-version
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "bats-version: ok above the minimum" {
  stub_bats_version 1.11.1
  run sh "$MIGRATE" --only bats-version
  [ "$status" -eq 0 ]
}

@test "bats-version: pending on 1.2.1 (the Debian/Ubuntu version)" {
  stub_bats_version 1.2.1
  run sh "$MIGRATE" --only bats-version
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR"* ]]
}

@test "bats-version: pending across a major boundary (0.4 < 1.5)" {
  stub_bats_version 0.4.0
  run sh "$MIGRATE" --only bats-version
  [ "$status" -eq 1 ]
}

@test "bats-version: --fix runs the fallback installer and re-checks" {
  stub_bats_version 1.2.1
  mkdir -p "$FAKE_ROOT/packages/scripts"
  # Stand in for packages/scripts/bats.sh: leaves a marker and
  # "upgrades" the stub it is checked against.
  cat > "$FAKE_ROOT/packages/scripts/bats.sh" <<EOF
#!/bin/sh
touch "$SANDBOX/installer-ran"
printf '#!/bin/sh\ncase "\$1" in\n  --version) echo "Bats 1.11.1" ;;\n  *) exit 0 ;;\nesac\n' > "$STUB_BIN/bats"
chmod +x "$STUB_BIN/bats"
EOF
  chmod +x "$FAKE_ROOT/packages/scripts/bats.sh"

  run sh "$MIGRATE" --fix --only bats-version
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/installer-ran" ]
  [[ "$output" == *"upgraded to 1.11.1"* ]]
}

@test "bats-version: --fix reports honestly when the installer does not help" {
  stub_bats_version 1.2.1
  mkdir -p "$FAKE_ROOT/packages/scripts"
  printf '#!/bin/sh\nexit 0\n' > "$FAKE_ROOT/packages/scripts/bats.sh"
  chmod +x "$FAKE_ROOT/packages/scripts/bats.sh"

  run sh "$MIGRATE" --fix --only bats-version
  [ "$status" -eq 1 ]
  [[ "$output" == *"still 1.2.1"* ]]
}

@test "bats-version: --fix warns when the fallback installer is missing" {
  stub_bats_version 1.2.1
  run sh "$MIGRATE" --fix --only bats-version
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot upgrade bats"* ]]
}

# --- legacy-home-git --------------------------------------------------------

@test "legacy-home-git: ok when \$HOME is not a git work tree" {
  run sh "$MIGRATE" --only legacy-home-git
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "legacy-home-git: MANUAL when ~/.git exists" {
  git init -q "$HOME"
  run sh "$MIGRATE" --only legacy-home-git
  [ "$status" -eq 1 ]
  [[ "$output" == *"MANUAL"* ]]
  [[ "$output" == *"$HOME/.git"* ]]
}

@test "legacy-home-git: MANUAL for a leftover ~/.gitignore alone" {
  # The ignore file is half the trap on its own: it is read
  # work-tree-relative, so it silently governs the private bare repo.
  printf '.ssh\n' > "$HOME/.gitignore"
  run sh "$MIGRATE" --only legacy-home-git
  [ "$status" -eq 1 ]
  [[ "$output" == *"MANUAL"* ]]
  [[ "$output" == *"$HOME/.gitignore"* ]]
}

@test "legacy-home-git: --fix never removes the repo on its own" {
  git init -q "$HOME"
  printf '.ssh\n' > "$HOME/.gitignore"
  run sh "$MIGRATE" --fix --only legacy-home-git
  [ "$status" -eq 1 ]
  [ -d "$HOME/.git" ]
  [ -f "$HOME/.gitignore" ]
  [[ "$output" == *"mv ~/.git"* ]]
}

@test "legacy-home-git: reports uncommitted work so the decision is informed" {
  git init -q "$HOME"
  git --git-dir="$HOME/.git" --work-tree="$HOME" config user.email t@e.com
  git --git-dir="$HOME/.git" --work-tree="$HOME" config user.name t
  git --git-dir="$HOME/.git" --work-tree="$HOME" config commit.gpgsign false
  printf 'one\n' > "$HOME/tracked.txt"
  git --git-dir="$HOME/.git" --work-tree="$HOME" add tracked.txt
  git --git-dir="$HOME/.git" --work-tree="$HOME" commit -q -m init
  printf 'two\n' > "$HOME/tracked.txt"

  run sh "$MIGRATE" --fix --only legacy-home-git
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 tracked file(s) with uncommitted changes"* ]]
}

# --- pending-packages / --quiet --------------------------------------------

@test "pending-packages: pending when install-packages reports work to do" {
  cat > "$FAKE_ROOT/scripts/install-packages.sh" <<'IP'
#!/bin/sh
echo "[install-packages] to install: wl-clipboard nfs-common"
IP
  chmod +x "$FAKE_ROOT/scripts/install-packages.sh"
  run sh "$MIGRATE" --only pending-packages
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR"* ]]
}

@test "pending-packages: pending when only a fallback script has work to do" {
  # A SKIP tool installed by its fallback script used to read as "nothing
  # to install", so --fix never ran the script.
  cat > "$FAKE_ROOT/scripts/install-packages.sh" <<'IP'
#!/bin/sh
echo "[install-packages] to install: (none)"
echo "[install-packages] to install via fallback script: docker-compose"
IP
  chmod +x "$FAKE_ROOT/scripts/install-packages.sh"
  run sh "$MIGRATE" --only pending-packages
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR"* ]]
}

@test "pending-packages: ok when nothing is outstanding" {
  cat > "$FAKE_ROOT/scripts/install-packages.sh" <<'IP'
#!/bin/sh
echo "[install-packages] already installed: git tmux"
IP
  chmod +x "$FAKE_ROOT/scripts/install-packages.sh"
  run sh "$MIGRATE" --only pending-packages
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "pending-packages: ok when install-packages reports its '(none)' sentinel" {
  # The real installer never omits the line: with nothing to do it
  # prints "to install: (none)", which must not read as a package name.
  cat > "$FAKE_ROOT/scripts/install-packages.sh" <<'IP'
#!/bin/sh
echo "[install-packages] already installed: git tmux"
echo "[install-packages] skipped (SKIP): (none)"
echo "[install-packages] to install: (none)"
IP
  chmod +x "$FAKE_ROOT/scripts/install-packages.sh"
  run sh "$MIGRATE" --only pending-packages
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "--quiet: a clean machine prints only the one summary line" {
  printf '#!/bin/sh\necho "[install-packages] to install: (none)"\n' \
    > "$FAKE_ROOT/scripts/install-packages.sh"
  chmod +x "$FAKE_ROOT/scripts/install-packages.sh"
  run sh "$MIGRATE" --quiet --only pending-packages
  [ "$status" -eq 0 ]
  [ "$output" = "[migrate] machine state is up to date" ]
}

@test "--quiet: pending work is still reported (and still exits 1), minus the ok lines" {
  printf '#!/bin/sh\necho "[install-packages] to install: wl-clipboard"\n' \
    > "$FAKE_ROOT/scripts/install-packages.sh"
  chmod +x "$FAKE_ROOT/scripts/install-packages.sh"
  printf '#!/bin/sh\nexit 0\n' > "$FAKE_ROOT/scripts/run-postinstall.sh"
  chmod +x "$FAKE_ROOT/scripts/run-postinstall.sh"
  run sh "$MIGRATE" --quiet --only pending-packages --only postinstall-hooks
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR"* ]]
  [[ "$output" == *"dj migrate --fix --only pending-packages"* ]]
  [[ "$output" == *"1 pending migration(s)"* ]]
  # postinstall-hooks is satisfied here; quiet mode must not list it.
  [[ "$output" != *"post-install hook"* ]]
}

@test "-q is short for --quiet" {
  printf '#!/bin/sh\necho "[install-packages] to install: (none)"\n' \
    > "$FAKE_ROOT/scripts/install-packages.sh"
  chmod +x "$FAKE_ROOT/scripts/install-packages.sh"
  run sh "$MIGRATE" -q --only pending-packages
  [ "$status" -eq 0 ]
  [ "$output" = "[migrate] machine state is up to date" ]
}

# --- selection --------------------------------------------------------------

@test "migrate: --only restricts the run to the named migration" {
  make_bare_with_origin
  mkdir -p "$HOME/.git"
  run sh "$MIGRATE" --only git-refspec
  [ "$status" -eq 1 ]
  [[ "$output" != *"MANUAL"* ]]
}

@test "migrate: without --only every applicable migration is evaluated" {
  make_bare_with_origin
  mkdir -p "$HOME/.git"
  run sh "$MIGRATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR"* ]]
  [[ "$output" == *"MANUAL"* ]]
}

# --- nixos-flake-applied ----------------------------------------------------
#
# A stub `nix` answers the two evaluations the check makes: the list of
# nixosConfigurations (NIX_HOSTS) and this host's system path (NIX_WANT,
# or an evaluation error when NIX_EVAL_FAIL=1). /run/current-system is a
# sandbox symlink.

nixos_flake_setup() {
  printf 'ID=nixos\n' > "$SANDBOX/os-release"
  export DOTFILES_OS_RELEASE_FILE="$SANDBOX/os-release"
  export DOTFILES_NIXOS_FLAKE="$HOME/.config/nixos"
  mkdir -p "$DOTFILES_NIXOS_FLAKE" "$SANDBOX/store/sys-a" "$SANDBOX/store/sys-b"
  printf '{ }\n' > "$DOTFILES_NIXOS_FLAKE/flake.nix"
  ln -sfn "$SANDBOX/store/sys-a" "$SANDBOX/current-system"
  export DOTFILES_CURRENT_SYSTEM="$SANDBOX/current-system"
  export NIX_HOSTS='["nixhost","other"]' NIX_WANT="$SANDBOX/store/sys-a"
  printf '#!/bin/sh\necho nixhost\n' > "$STUB_BIN/hostname"
  cat > "$STUB_BIN/nix" <<'STUB'
#!/bin/sh
echo "nix $*" >> "$SANDBOX/stub.log"
case "$*" in
  *--apply*) printf '%s' "$NIX_HOSTS" ;;
  *outPath*) [ "${NIX_EVAL_FAIL:-0}" = 1 ] && exit 1; printf '%s' "$NIX_WANT" ;;
esac
STUB
  stub_sudo_passthrough
  stub_cmd nixos-rebuild
  chmod +x "$STUB_BIN/hostname" "$STUB_BIN/nix"
}

@test "nixos-flake-applied: N/A (silent) off NixOS" {
  nixos_flake_setup
  printf 'ID=debian\n' > "$SANDBOX/os-release"
  run sh "$MIGRATE" --only nixos-flake-applied
  [ "$status" -eq 0 ]
  [[ "$output" != *"NixOS system"* ]]
}

@test "nixos-flake-applied: N/A without ~/.config/nixos/flake.nix" {
  nixos_flake_setup
  rm "$DOTFILES_NIXOS_FLAKE/flake.nix"
  run sh "$MIGRATE" --only nixos-flake-applied
  [ "$status" -eq 0 ]
  [[ "$output" != *"NixOS system"* ]]
}

@test "nixos-flake-applied: N/A when the flake doesn't describe this host" {
  nixos_flake_setup
  export NIX_HOSTS='["other"]'
  run sh "$MIGRATE" --only nixos-flake-applied
  [ "$status" -eq 0 ]
  [[ "$output" != *"NixOS system"* ]]
}

@test "nixos-flake-applied: ok when the running system is the flake's" {
  nixos_flake_setup
  run sh "$MIGRATE" --only nixos-flake-applied
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"*"NixOS system"* ]]
  # Evaluated as a path flake, without touching flake.lock.
  grep -q 'eval --no-write-lock-file --raw path:.*/.config/nixos#nixosConfigurations.nixhost.config.system.build.toplevel.outPath' "$SANDBOX/stub.log"
}

@test "nixos-flake-applied: pending when the flake builds a different system" {
  nixos_flake_setup
  export NIX_WANT="$SANDBOX/store/sys-b"
  run sh "$MIGRATE" --only nixos-flake-applied
  [ "$status" -eq 1 ]
  [[ "$output" == *"dj migrate --fix --only nixos-flake-applied"* ]]
  ! stub_called nixos-rebuild
}

@test "nixos-flake-applied: pending when the flake fails to evaluate" {
  nixos_flake_setup
  export NIX_EVAL_FAIL=1
  run sh "$MIGRATE" --only nixos-flake-applied
  [ "$status" -eq 1 ]
}

@test "nixos-flake-applied: --fix switches to this host's flake output" {
  nixos_flake_setup
  export NIX_WANT="$SANDBOX/store/sys-b"
  run sh "$MIGRATE" --fix --only nixos-flake-applied
  grep -q "^nixos-rebuild switch --flake path:.*/.config/nixos#nixhost$" "$SANDBOX/stub.log"
}

@test "nixos-flake-applied: --fix does nothing when already applied" {
  nixos_flake_setup
  run sh "$MIGRATE" --fix --only nixos-flake-applied
  [ "$status" -eq 0 ]
  ! stub_called nixos-rebuild
}


# --- the migration-script protocol ----------------------------------------

@test "every core migration answers desc, and rejects an unknown verb" {
  export DJ_MIGRATION_LIB="$BATS_TEST_DIRNAME/../scripts/lib/migration.sh"
  for f in "$BATS_TEST_DIRNAME"/../migrations/*.sh; do
    run sh "$f" desc
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    run sh "$f" bogus
    [ "$status" -eq 2 ]
  done
}

@test "migrate: ids drop the NN- ordering prefix" {
  run sh "$MIGRATE" --list
  [[ "$output" == "git-refspec "* ]]
  [[ "$output" != *"10-git-refspec"* ]]
}
@test "postinstall-hooks: MANUAL when a listed hook has no script" {
  cat > "$FAKE_ROOT/scripts/run-postinstall.sh" <<'RP'
#!/bin/sh
echo "[run-postinstall] WARNING: no hook script for zfs-textfile-collector" >&2
exit 1
RP
  chmod +x "$FAKE_ROOT/scripts/run-postinstall.sh"
  run sh "$MIGRATE" --fix --only postinstall-hooks
  [ "$status" -eq 1 ]
  [[ "$output" == *"MANUAL"* ]]
  [[ "$output" == *"zfs-textfile-collector"* ]]
}

@test "postinstall-hooks: N/A on NixOS, even with an unresolved hook listed" {
  printf '#!/bin/sh\nexit 1\n' > "$FAKE_ROOT/scripts/run-postinstall.sh"
  printf 'ID=nixos\n' > "$SANDBOX/os-release"
  DOTFILES_OS_RELEASE_FILE="$SANDBOX/os-release" run sh "$MIGRATE" --only postinstall-hooks
  [ "$status" -eq 0 ]
  [[ "$output" != *"post-install hook"* ]]
}

@test "postinstall-hooks: ok when every listed hook resolves" {
  printf '#!/bin/sh\nexit 0\n' > "$FAKE_ROOT/scripts/run-postinstall.sh"
  chmod +x "$FAKE_ROOT/scripts/run-postinstall.sh"
  run sh "$MIGRATE" --only postinstall-hooks
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}


@test "migrate: a user migration in ~/.config/dj/migrations runs after the core ones" {
  mkdir -p "$HOME/.config/dj/migrations"
  cat > "$HOME/.config/dj/migrations/50-my-thing.sh" <<'MIG'
#!/bin/sh
. "${DJ_MIGRATION_LIB:?}"
desc() { echo "my thing is set up"; }
check() { [ -f "$HOME/my-thing" ] || return 1; }
fix() { touch "$HOME/my-thing"; }
migration_main "$@"
MIG
  run sh "$MIGRATE" --list
  [[ "${lines[-1]}" == "my-thing "*"auto"*"my thing is set up" ]]
  run sh "$MIGRATE" --only my-thing
  [ "$status" -eq 1 ]
  [[ "$output" == *"MIGR    my thing is set up"* ]]
  run sh "$MIGRATE" --fix --only my-thing
  [ "$status" -eq 0 ]
  [ -f "$HOME/my-thing" ]
}
