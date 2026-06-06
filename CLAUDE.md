# dotfiles

Personal dotfiles, secrets, and bootstrap tooling. Targets: **Linux** (apt/pacman, including Omarchy), **macOS** (brew), **WSL**. One command bootstraps a fresh machine; this file is the design doc, operating manual, and Claude working norms.

---

## 1. Goals

1. **One-command bootstrap** via `install.sh` + age key.
2. **Bare git repo** with `$HOME` as work tree; files added explicitly with `dot add`.
3. **Single `main` branch** for all OSes; differences handled by runtime detection.
4. **Secrets in repo, encrypted** with SOPS+age; age key is the only out-of-band transport.
5. **Plaintext secrets never committed** — pre-commit hook is the backstop.
6. **`Justfile` for daily ops**: sync, add, secret-edit, apply-secrets, doctor.
7. **Idempotent bootstrap** — re-running converges rather than replaces.
8. **bash and zsh parity** — shared POSIX layer; shell-specific details in per-shell files.
9. **Multi-user-on-one-host safe** — writes nothing outside `$HOME` except via package manager.
10. **Configs travel everywhere; software is tiered** — all tracked configs deploy to every machine; `--system-type` controls only which packages install.

Non-goals: not a system-configuration manager, not a fleet manager.

---

## 2. Design decisions

### 2.1 Bare git repo + `dot` alias

```bash
alias dot='git --git-dir=$HOME/.dotfiles.git --work-tree=$HOME'
dot config status.showUntrackedFiles no
```

`dot status` is blind to untracked files by design. `dot-add` makes adding new files routine. Rejected: chezmoi (unnecessary indirection), stow (symlink farm), yadm (wrapper around what we do ourselves).

### 2.2 SOPS + age secrets

- Encrypted files (`.enc`) committed; editing goes through `sops` (decrypt → `$EDITOR` → re-encrypt). Plaintext only in memory.
- Age key at `~/.config/sops/age/keys.txt` — only out-of-band transport.
- `.sops.yaml` supports multiple recipients for per-machine keys.

Rejected: gpg (fiddly on macOS), 1Password CLI (requires app + sign-in), git-crypt (smudge/clean filters break on non-git tools, rotation painful).

### 2.3 OS handling: single branch, runtime detection

`~/.config/shell/init.sh` sets `DOTFILES_OS` and sources the load chain:

```sh
case "$(uname -s)" in
  Darwin)  OS=darwin ;;
  Linux)
    if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then OS=wsl
    else OS=linux; fi ;;
esac
export DOTFILES_OS=$OS
# Load order: env → aliases → functions → os-specific → host-specific → secrets
for f in ~/.config/shell/env.sh ~/.config/shell/aliases.sh \
         ~/.config/shell/functions.sh ~/.config/shell/os/$OS.sh \
         ~/.config/shell/host/$(hostname -s 2>/dev/null || hostname).sh \
         ~/.config/shell/secrets.sh; do
  [ -r "$f" ] && . "$f"
done
```

### 2.4 Shell handling: bash and zsh share a POSIX layer

- **`~/.config/shell/`** — POSIX-only (must run under `dash`). No `[[`, `local`, arrays, `function name()`.
- **`~/.config/bash/`** — bash-only: `HISTCONTROL`, `shopt`, completion, `eval "$(starship init bash)"`, bashisms.
- **`~/.config/zsh/`** — zsh-only: `zstyle`, `compinit`, `setopt`, `eval "$(starship init zsh)"`.
- **`~/.bashrc` / `~/.zshrc`** — tiny loaders: source shared layer then shell-specific init.

### 2.5 Bootstrap: `install.sh` vs `Justfile`

`install.sh` — POSIX sh, idempotent, for cold starts: detect pkg manager, install tools, clone bare repo, conflict-aware checkout, install pre-commit hook, optionally install age key, auto-initialize SOPS, apply secrets, offer shell consolidation, set up git identity/SSH/GPG. `Justfile` — daily ops post-bootstrap. Two entry points because bootstrap and daily concerns differ.

### 2.6 Don't fight distro/desktop

Track a file only if it diverges from what the system would have shipped. On Omarchy: prefer override hooks (`~/.config/hypr/<file>.conf`, `~/.config/omarchy/`) over wholesale file replacement. `dj config-diff` audits what's worth tracking.

### 2.7 System tier

| Tier | What's added |
|---|---|
| _(none)_ | common: git, sops, age, nvim, tmux, starship, rg, fd, fzf, jq, gh, … |
| `desktop` | waybar, mako, walker, image viewers, fonts |
| `server` | htop, btop, ncdu, restic, fail2ban, … |

- **Tier governs software, not config.** All tracked configs deploy uniformly.
- **Choice persists** at `~/.config/dotfiles/system-type`. Never auto-detect from `$DISPLAY`.
- Shell init must guard tier-specific binaries: `command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init bash)"`.

---

## 3. Repository layout

```
$HOME (work tree)
├── .dotfiles.git/                      # bare git dir
├── .bashrc  .bash_profile  .zshrc  .zprofile  .gitignore   # tracked loaders
├── .config/
│   ├── shell/                          # POSIX shared layer
│   │   ├── init.sh  env.sh  aliases.sh  functions.sh  secrets.sh
│   │   ├── os/{linux,darwin,wsl}.sh
│   │   └── host/<hostname>.sh
│   ├── bash/    init.sh  functions.sh  completion.sh  prompt.sh
│   ├── zsh/     init.sh  functions.sh  completion.sh  prompt.sh
│   ├── git/  nvim/  tmux/  starship.toml
│   ├── alacritty/  ghostty/  kitty/
│   ├── hypr/  waybar/  mako/  walker/  omarchy/
│   └── sops/age/keys.txt               # NOT tracked; out-of-band transport target
├── .dotfiles/                          # operational tooling + Claude context
│   ├── CLAUDE.md                        # this file (Claude project memory)
│   ├── .claude/skills/<name>/SKILL.md  # project-scope skills (NOT global)
│   ├── install.sh                      # POSIX sh bootstrap
│   ├── Justfile                        # daily ops (invoke via `dj`)
│   ├── scripts/
│   │   ├── os-detect.sh               # DOTFILES_OS, _PKG, _DISTRO, _SYSTEM_TYPE
│   │   ├── install-packages.sh        # idempotent, SKIP semantics, fallback scripts
│   │   ├── rebuild-secrets.sh         # manifest → target paths
│   │   ├── pre-commit-secrets.sh      # rejects plaintext secrets + gitleaks scan
│   │   ├── shell-consolidate.sh       # migrate/create ~/.config/{shell,bash,zsh}/
│   │   ├── git-setup.sh               # git identity, SSH key, GPG key (first-run)
│   │   ├── config-diff.sh  audit-config.sh  sops-init.sh
│   │   ├── claude-creds-snapshot.sh   # Linux/WSL only
│   │   └── install-claude.sh          # vendor curl-pipe, idempotent
│   ├── packages/
│   │   ├── common.txt  desktop.txt  server.txt
│   │   ├── renames/{apt,pacman,brew}.txt   # `logical actual` per line; SKIP to omit
│   │   └── scripts/{sops,just,starship}.sh # fallback installers
│   ├── secrets/
│   │   ├── manifest.txt.enc           # src → dst + mode map (SOPS-encrypted)
│   │   └── env/api-keys.env.enc
│   └── tests/                         # bats suite
├── .ssh/
│   ├── config                          # tracked iff no host secrets
│   ├── id_*                            # NEVER tracked plaintext; via apply-secrets
│   └── known_hosts                     # NOT tracked
```

`README.md`, `.bashrc`, `.zshrc`, `.config/**` → tracked at repo root, deploy to `$HOME` (where the tools read them). Everything operational → under `.dotfiles/`, deploys to `~/.dotfiles/`. Bare git dir: `~/.dotfiles.git/`. There is **no dev clone**: Claude runs from `~/.dotfiles/` and edits the live `$HOME` files directly through the bare repo (see §10).

`CLAUDE.md` and `.claude/skills/` deliberately live **under `.dotfiles/`**, not at the repo root. The repo root is `$HOME`, so tracking them there would deploy `$HOME/CLAUDE.md` and `$HOME/.claude/skills/` — i.e. make them global to every Claude session anywhere under `$HOME`. Keeping them under `~/.dotfiles/` scopes them to this project (loaded only when launched from `~/.dotfiles/`).

### 3.1 The Justfile and `dj`

```sh
dj() { JUST_JUSTFILE="$HOME/.dotfiles/Justfile" just "$@"; }
```

Always use `dj` not `just` — the Justfile is at `~/.dotfiles/Justfile`, not `$HOME`.

---

## 4. Workflows

### 4.1 Fresh machine

```sh
# Transport ~/.config/sops/age/keys.txt first (or pass --age-key <path>).
curl -fsSL https://raw.githubusercontent.com/<you>/dotfiles/main/install.sh | sh
# With tier and inline age key:
curl -fsSL https://raw.githubusercontent.com/<you>/dotfiles/main/install.sh \
  | sh -s -- --system-type desktop --age-key ~/keys.txt
```

`install.sh` steps:
1. Detect OS + pkg manager (abort if none of apt/pacman/brew).
2. Bootstrap git if missing.
3. Persist `--system-type`; resolve and install packages.
4. `git clone --bare … $HOME/.dotfiles.git`.
5. Conflict-aware checkout — classify existing files as **identical** (silently remove, git re-creates), **symlink** (always back up), or **conflict**. Conflicts dispatch on `--on-conflict {ask|backup|keep|abort}` (default `ask`; non-interactive shells must pass explicit mode).
6. `dot config status.showUntrackedFiles no`.
7. Install pre-commit hook into `.dotfiles.git/hooks/`.
8. Install age key — from `--age-key <path>` if provided, or interactive paste, or skip.
9. Initialize SOPS — run `sops-init.sh` (generate age key + write `.sops.yaml`) if sops and age-keygen are present and not yet done.
10. Apply secrets (`dj apply-secrets`) if age key is present.
11. Optional cleanup of local source clone.
12. Offer shell consolidation (`shell-consolidate.sh`) — migrate or create `~/.config/{shell,bash,zsh}/`.
13. Git identity, SSH key, GPG key (`git-setup.sh`) — adopt existing config, prompt if missing, generate keys if absent.
14. Print next steps.

Multi-user: steps 1–3 may `sudo` for system packages (idempotent); steps 4+ touch only invoking user's `$HOME`.

### 4.2 Adding a file

```sh
dot-add ~/.config/some-tool/config.toml   # wraps: dot add <path> && dot status
```

### 4.3 Adding a secret

```sh
dj secret-add ~/.ssh/id_ed25519           # encrypt, update manifest, stage both
dj secret-add ~/staging-key ~/.ssh/id_ed25519 0600   # explicit dst + mode
dot commit -m 'secrets: add ssh key' && dot push
```

`secret-add` infers enc path (`secrets/<rel>.enc`), dst (source path), and mode (source permissions). Duplicate entries are warned and skipped.

### 4.4 Editing an existing secret

```sh
dj secret-edit env/api-keys    # → sops ~/.dotfiles/secrets/env/api-keys.env.enc
dj apply-secrets                # re-materialize to target paths
```

### 4.5 Syncing and upgrading

```sh
dj sync            # dot pull --rebase && dj apply-secrets
dj upgrade         # dj sync && dj install-packages
dj system-type desktop   # update persisted tier (does NOT install packages)
```

`apply-secrets` is bundled with `sync` because pulls can update encrypted material. Package install is separate to keep `sync` fast and sudo-free.

### 4.6 Sanity check

```sh
dj doctor
```

Reports `DOTFILES_OS/PKG/DISTRO/SYSTEM_TYPE`. Checks: sops/age present; age key readable; `.sops.yaml` decrypts canary; SSH key perms 0600; every tool in active tier installed or SKIP-marked. Missing desktop binaries on `server` tier not flagged.

---

## 5. Secrets

### 5.1 Manifest

`.dotfiles/secrets/manifest.txt.enc` (SOPS-encrypted) maps encrypted files to targets:

```
.dotfiles/secrets/env/api-keys.env.enc  ~/.secrets/api-keys.env  0600
.dotfiles/secrets/ssh/id_ed25519.enc    ~/.ssh/id_ed25519                0600
.dotfiles/secrets/ssh/config.enc        ~/.ssh/config                    0600
```

`dj apply-secrets` (`rebuild-secrets.sh`) iterates the manifest: decrypt src → write dst with mode. Idempotent.

### 5.2 Pre-commit hook

Rejects a commit when:
1. Any staged path matches `.dotfiles/secrets/**` but doesn't end in `.enc`, `.pub`, `.md`, or `.example`.
2. `gitleaks` (if installed) finds credentials in non-secrets staged files.

Backstop only — primary control is that `sops` editing never produces a plaintext working file.

### 5.3 Cross-machine SSH trust

All machines share the same identity (`.dotfiles/secrets/ssh/id_ed25519.enc` → `~/.ssh/id_ed25519`). Track `~/.ssh/authorized_keys` so every machine gets the public key on bootstrap:

```sh
cp ~/.ssh/id_ed25519.pub ~/.ssh/authorized_keys
chmod 0600 ~/.ssh/authorized_keys
dot-add ~/.ssh/authorized_keys
dot commit -m 'ssh: track authorized_keys for cross-machine trust'
dot push
```

### 5.4 Rotating the age key

1. Generate new keypair; add new public key to `.sops.yaml`.
2. `find ~/.dotfiles/secrets -name '*.enc' -exec sops updatekeys {} \;`
3. Commit, push, distribute new private key out-of-band.
4. Once all machines have it: remove old key from `.sops.yaml`, re-run `updatekeys`, commit.

---

## 6. OS, shell, and host conditionalization

- **OS detection**: centralized in `os-detect.sh` and `shell/init.sh`. Names: `darwin`, `linux`, `wsl`.
- **Pkg manager**: `apt | pacman | brew` (preference order). Exported as `DOTFILES_PKG`.
- **Distro**: reads `ID` from `/etc/os-release` (e.g. `ubuntu`, `debian`, `arch`). Exported as `DOTFILES_DISTRO`. Used to resolve renames via `renames/$DISTRO.txt` before falling back to `renames/$PKG.txt`.
- **System tier**: read from `~/.config/dotfiles/system-type`; exported as `DOTFILES_SYSTEM_TYPE`.
- **Shell detection**: implicit via `.bashrc`/`.zshrc`. Never branch on `$SHELL` inside `shell/*`.
- **Per-OS config**: `~/.config/shell/os/<os>.sh` (sourced after shared layer).
- **Per-host config**: `~/.config/shell/host/<hostname>.sh` (sourced last; optional).
- **Package lists**: `common.txt` is source of truth; renames files carry only per-manager name overrides.

---

## 7. Distro- and desktop-managed configs

Two orthogonal rules:
1. **Tracking**: only divergence from what the system would have shipped.
2. **Deployment**: unconditional — tracked files check out on every machine regardless of OS/tier.

**Omarchy (Arch)**: source in `~/.local/share/omarchy/`. Track only divergence; use override hooks (`~/.config/hypr/<file>.conf`, `~/.config/omarchy/`) over wholesale replacement. **`omarchy` Skill is mandatory** for any change under `~/.config/{hypr,waybar,walker,alacritty,kitty,ghostty,mako,omarchy}` on Omarchy hosts.

**Plain Linux**: compare against package-shipped sample (`/usr/share/<tool>/` or `/etc/<tool>/`).

**macOS**: `~/Library/Preferences/*.plist` and `defaults` DB — not tracked (binary, user-graph-specific). Use `~/.dotfiles/scripts/macos-defaults.sh` + `dj apply-macos-defaults` for persistent settings.

**WSL**: treat as Linux for shell/tools. Windows-side (Terminal profile, fonts) out of scope.

---

## 8. Implementation status

**Complete:** install.sh (POSIX, idempotent, --system-type, --on-conflict, --age-key, three-bucket conflict classification, auto sops-init, shell consolidation, git setup); Justfile (sync, upgrade, add, secret-add, secret-edit, apply-secrets, install-packages, system-type, sops-init, doctor, config-diff, audit-config, test); os-detect.sh; install-packages.sh (SKIP semantics, fallback scripts); packages/scripts/{sops,just,starship}.sh; rebuild-secrets.sh; secret-add.sh (encrypt + manifest update + stage); pre-commit-secrets.sh; sops-init.sh (auto-called from install.sh); shell-consolidate.sh (migrate or create ~/.config/{shell,bash,zsh}/, atomic conflict check); git-setup.sh (identity + SSH + GPG, idempotent); config-diff.sh; audit-config.sh; packages/{common,desktop,server}.txt (gpg in common); renames/{apt,pacman,brew}.txt; shell/{init,env,aliases,functions,secrets}.sh; shell/os/{linux,darwin,wsl}.sh; bash/{init,functions,completion,prompt}.sh; zsh/{init,functions,completion,prompt}.sh; bats coverage for all scripts (245 tests, ~20 skipped pending sops/age/zsh); claude-creds-snapshot.sh; install-claude.sh; `dj claude`; project skills (install-package, query-config, dispatch-just, edit-config).

**Outstanding (user task only):**
- [ ] Initial secrets — run `dj secret-add <file>` for each secret (`dj sops-init` is now called automatically by install.sh, but may need to be run manually if skipped).
- [ ] Stage `~/.config/*` files identified by `dj audit-config -q` via `dot-add`.

---

## 9. Working norms for Claude in this repo

- **POSIX `sh` for `install.sh` and `scripts/`** — bootstrap runs on a fresh machine. `~/.config/{bash,zsh}/` can use host shell features freely.
- **POSIX in `~/.config/shell/*`** — must run under `dash`. `[[`, `local`, arrays, `function name()` belong in bash/zsh sub-trees.
- **Idempotence over cleverness** — every script safe to re-run; `install.sh` must converge.
- **Never write plaintext secrets to disk** — only `rebuild-secrets.sh` (to declared `dst`) and sops temp file.
- **One home for OS/pkg detection** — `os-detect.sh` and `shell/init.sh`. If they disagree, fix the script.
- **Fallback installers** — when a tool is absent from apt/pacman/brew, mark it `SKIP` in the renames file and add `packages/scripts/<name>.sh`. Must be POSIX sh, idempotent, install to `/usr/local/bin` via `sudo`. `install-packages.sh` runs matching scripts automatically.
- **Multi-user safety** — nothing outside `$HOME` except via the package manager. No `/etc/`, `/usr/local/etc/`, `~root/` writes.
- **Use override hooks** — before replacing upstream files, run `dj config-diff`; only stage actual divergence.
- **Invoke the `omarchy` Skill** for any change under `~/.config/{hypr,waybar,walker,alacritty,kitty,ghostty,mako,omarchy}` on Omarchy hosts (detect: `/etc/os-release` + presence of `~/.local/share/omarchy/`).
- **`status.showUntrackedFiles=no`** on the bare repo — don't "fix" it; it's load-bearing.
- **Every `scripts/` script gets bats coverage** in `.dotfiles/tests/<name>.bats` in the same commit. Use sandbox helpers in `test_helper.bash`.
- **Use `dj` not `just`** — Justfile is at `~/.dotfiles/Justfile`, not `$HOME`.
- **Configs deploy everywhere; software is tiered** — guard tier-specific binaries with `command -v <tool> >/dev/null 2>&1 &&`.
- **Don't auto-detect system tier** — persisted via `--system-type`; inferring from `$DISPLAY` will be wrong in edge cases.
- **`~/.config/dotfiles/system-type` is host-local state** — never track in the repo; refuse if asked and explain.

---

## 10. Claude Code integration: `dj claude` and project skills

### 10.1 `dj claude`

```sh
dj claude                               # interactive session
dj claude install pv and add to common  # one-shot (claude -p)
```

`dj claude` (a `Justfile` target) `cd`s into `~/.dotfiles/` then launches `claude`. Requires `claude` on PATH.

**Single repo, no dev clone.** `~/.dotfiles/` is the operational root — it carries this `CLAUDE.md`, the `.claude/skills/`, and the bulk of the editable tooling (`scripts/`, `tests/`, `Justfile`, `packages/`, `secrets/`). Claude edits the **live `$HOME` files directly** through the bare repo: configs at `~/.config/**`, loaders like `~/.bashrc`, tooling under `~/.dotfiles/`. Git operations go through the `dot` alias (`git --git-dir=$HOME/.dotfiles.git --work-tree=$HOME`); the cwd (`~/.dotfiles/`) is not itself a normal git worktree, so use `dot`, not bare `git`, for status/add/commit. Because there is exactly one copy of every file (no clone to keep in sync), tests run against the same files Claude edits — no drift, no lost updates.

### 10.2 Project skills

`~/.dotfiles/.claude/skills/<name>/SKILL.md` — project-scope, loaded only when Claude is launched from `~/.dotfiles/`:

| Skill | Purpose |
|---|---|
| `install-package` | Install tool + register in `packages/` with per-OS renames |
| `query-config` | Answer questions about config and machine state |
| `dispatch-just` | Map natural-language intent to the right `dj` verb |
| `edit-config` | Edit tracked config honoring override-hook and POSIX-layer rules |

Kept project-scope intentionally. They live under `~/.dotfiles/`, **not** at the repo root — tracking them at the root would deploy them to `~/.claude/skills/` (the user-global location) and pollute every Claude session. Same reasoning for `CLAUDE.md` (see §3).

### 10.3 Claude Code as a package

`claude` in `common.txt`, marked `SKIP` in all renames files (no apt/pacman/brew package). `install.sh` runs `install-claude.sh` after package installs:

```sh
curl -fsSL https://claude.ai/install.sh | sh   # overridable via $CLAUDE_INSTALL_URL
```

Idempotent (`command -v claude` short-circuits). Exits non-zero if `claude` ends up off PATH.

### 10.4 Auth: encrypted credentials snapshot (Linux/WSL only)

```sh
# After `claude login`:
dj claude-creds-snapshot   # encrypts ~/.claude/.credentials.json,
                           # updates manifest.txt.enc, stages both
dot commit -m 'claude: refresh credentials snapshot' && dot push

# Other machines:
dj sync   # pulls + applies secrets → rematerializes credentials
```

Tokens drift over time; re-run `dj claude-creds-snapshot` when expired. macOS: uses Keychain, no flat file — always `claude login` interactively.

### 10.5 Norms for Claude when invoked via `dj claude`

- **Edit the live `$HOME` files directly — there is no dev clone.** To change shell functions, edit `~/.config/shell/functions.sh`; to change a script, edit `~/.dotfiles/scripts/<name>.sh`. These are the real tracked files; the bare repo's work-tree is `$HOME`, so your edits *are* the change. Do not look for or recreate a `~/Projects/dotfiles` clone.
- **Use `dot`, not `git`, for repo operations.** Stage with `dot add <path>` (or `dot-add`), inspect with `dot status`, diff with `dot diff`. Plain `git` from `~/.dotfiles/` does not see the bare repo.
- **Don't commit without explicit approval.** Leave changes staged via `dot add`; the user runs `dot commit && dot push`. No `dj sync` is needed afterward — the edited files are already the deployed files.
- **Verify before claiming success.** "Added pv to common" = `command -v pv` returns a path AND the change shows in `dot status`.
- **Tests run against the live tree.** `dj test` (or `bats ~/.dotfiles/tests/`) exercises the same `~/.dotfiles/scripts/` you edit. There is no second copy that can pass while the real one is broken.
