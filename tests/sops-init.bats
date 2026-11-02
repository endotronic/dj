#!/usr/bin/env bats
#
# Tests for scripts/sops-init.sh: first-time SOPS setup. Most tests
# require sops + age-keygen installed; they skip otherwise.

load test_helper

setup() {
  sandbox_setup
  stub_dir_setup
  # PRIVATE_DIR tells sops-init.sh where to write .sops.yaml;
  # no script copy needed since PRIVATE_DIR is the canonical path.
  FAKE_REPO="$SANDBOX/fake-repo"
  mkdir -p "$FAKE_REPO"
  export FAKE_REPO PRIVATE_DIR="$FAKE_REPO"
  SOPS_INIT="$DOTFILES_REPO_ROOT/scripts/sops-init.sh"
}

teardown() {
  sandbox_teardown
}

requires_sops_and_age() {
  command -v sops >/dev/null 2>&1 || skip "sops not installed"
  command -v age-keygen >/dev/null 2>&1 || skip "age not installed"
}

# --- happy path (requires sops + age) ------------------------------------

@test "generates an age key when missing, writes .sops.yaml" {
  requires_sops_and_age
  run sh "$SOPS_INIT"
  [ "$status" -eq 0 ]
  [ -f "$XDG_CONFIG_HOME/sops/age/keys.txt" ]
  [ -f "$FAKE_REPO/.sops.yaml" ]
  # The .sops.yaml mentions the public key from the generated keyfile.
  pub=$(awk '/^# public key:/ { print $NF }' "$XDG_CONFIG_HOME/sops/age/keys.txt")
  [ -n "$pub" ]
  grep -qF "$pub" "$FAKE_REPO/.sops.yaml"
}

@test "generated key file has mode 0600" {
  requires_sops_and_age
  sh "$SOPS_INIT" >/dev/null
  mode=$(stat -c '%a' "$XDG_CONFIG_HOME/sops/age/keys.txt" 2>/dev/null \
       || stat -f '%Lp' "$XDG_CONFIG_HOME/sops/age/keys.txt")
  [ "$mode" = "600" ]
}

@test "key directory ~/.config/sops/age has mode 0700" {
  requires_sops_and_age
  sh "$SOPS_INIT" >/dev/null
  mode=$(stat -c '%a' "$XDG_CONFIG_HOME/sops/age" 2>/dev/null \
       || stat -f '%Lp' "$XDG_CONFIG_HOME/sops/age")
  [ "$mode" = "700" ]
}

@test "idempotent: re-running does not regenerate the key" {
  requires_sops_and_age
  sh "$SOPS_INIT" >/dev/null
  first=$(cat "$XDG_CONFIG_HOME/sops/age/keys.txt")
  sh "$SOPS_INIT" >/dev/null
  second=$(cat "$XDG_CONFIG_HOME/sops/age/keys.txt")
  [ "$first" = "$second" ]
}

@test "preserves an existing .sops.yaml" {
  requires_sops_and_age
  printf '# user-customized .sops.yaml\n' > "$FAKE_REPO/.sops.yaml"
  sh "$SOPS_INIT" >/dev/null
  grep -q "user-customized" "$FAKE_REPO/.sops.yaml"
}

@test "writes .sops.yaml when only the age key already exists" {
  requires_sops_and_age
  # Pre-generate a key but no .sops.yaml.
  age-keygen -o "$XDG_CONFIG_HOME/sops/age/keys.txt" 2>/dev/null
  chmod 600 "$XDG_CONFIG_HOME/sops/age/keys.txt"
  rm -f "$FAKE_REPO/.sops.yaml"
  run sh "$SOPS_INIT"
  [ "$status" -eq 0 ]
  [ -f "$FAKE_REPO/.sops.yaml" ]
  pub=$(awk '/^# public key:/ { print $NF }' "$XDG_CONFIG_HOME/sops/age/keys.txt")
  grep -qF "$pub" "$FAKE_REPO/.sops.yaml"
}

# --- failure-path tests (don't need sops/age) ----------------------------

@test "errors clearly if age-keygen is missing" {
  # Stash core utilities into the stub dir BEFORE narrowing PATH.
  for util in awk cat chmod dirname mkdir; do
    src=$(command -v "$util")
    [ -n "$src" ] && [ -f "$src" ] && cp "$src" "$STUB_BIN/$util" \
      && chmod +x "$STUB_BIN/$util"
  done
  # Capture absolute sh path before narrowing PATH.
  abs_sh=$(command -v sh)
  # Stub sops so the sops check passes; age-keygen stays absent.
  stub_cmd sops
  PATH="$STUB_BIN"
  run "$abs_sh" "$SOPS_INIT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "age-keygen not found" ]]
}

@test "errors clearly if sops is missing" {
  for util in awk cat chmod dirname mkdir; do
    src=$(command -v "$util")
    [ -n "$src" ] && [ -f "$src" ] && cp "$src" "$STUB_BIN/$util" \
      && chmod +x "$STUB_BIN/$util"
  done
  abs_sh=$(command -v sh)
  stub_cmd age-keygen
  PATH="$STUB_BIN"
  run "$abs_sh" "$SOPS_INIT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "sops not found" ]]
}
