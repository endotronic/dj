# dj design

What dj does, and why it's shaped the way it is. The README covers how to
use it; this covers the decisions.

## 1. Goals

1. **One-command bootstrap**: `install.sh` plus your age key turns a fresh
   machine into one of yours.
2. **Your `$HOME` is the work tree.** Config files are tracked where they
   live, in a bare git repo; there's no source tree to render from.
3. **One branch for every OS.** Differences are handled at runtime.
4. **Secrets in the repo, encrypted** with SOPS + age; the age key is the
   only thing you carry by hand.
5. **Plaintext secrets are never committed**; a pre-commit hook is the
   backstop.
6. **Idempotent.** Every script converges when re-run.
7. **Old machines catch up.** Repairs for state an older bootstrap never
   set up are first-class (migrations, §9).
8. **bash and zsh parity** through a shared POSIX layer.
9. **Multi-user safe.** Nothing outside `$HOME` except through the package
   manager or an explicit post-install hook.
10. **Configs travel everywhere; software is typed.** Every tracked file
    lands on every machine; a system type only picks which package lists
    apply.

Non-goals: dj is not a system-configuration manager (NixOS's flake is, on
NixOS), and not a fleet orchestrator.

## 2. Two repos

| | public engine (this repo) | your private repo |
|---|---|---|
| where | `~/.dotfiles/`, a normal clone | `~/.config.git`, bare, work tree `$HOME` |
| holds | scripts, tests, Justfile, mechanisms | your dotfiles, package/hook lists, modules.txt, encrypted secrets |
| git command | `git` inside `~/.dotfiles` | `dot` (`git --git-dir=~/.config.git --work-tree=$HOME`) |

The engine never contains anything about you; your repo never contains
the engine. `dj sync` pulls both: the engine first (fast-forward only, and
it only ever warns, since `~/.dotfiles` is also where you'd hack on dj),
then yours (rebase; a failure aborts).

**Why a bare repo over `$HOME`** rather than chezmoi/stow/yadm: tracked
files are the live files. There's nothing to apply, and nothing to drift
between a source and a rendered copy. The cost is that `$HOME` is full of
untracked files, so `status.showUntrackedFiles=no` is set on the repo (load
bearing; don't unset it) and new files are added explicitly
(`dj add`, `dot add`). `dj audit-config` helps find what's worth tracking.

**Your agent notes** live at `~/.config/dj/AGENTS.md` in your repo, never
at its root: the root is `$HOME`, and an `AGENTS.md`/`CLAUDE.md` there would
load into every agent session anywhere under your home directory.

## 3. OS, distro, package manager, system type

`scripts/os-detect.sh` is the one place these are derived:

- `DOTFILES_OS`: `darwin | linux | wsl | unknown`
- `DOTFILES_DISTRO`: `ID` from `/etc/os-release`
- `DOTFILES_PKG`: `nix` on NixOS (by os-release ID, never by `nix` on PATH,
  since Nix installs on other distros too), else `apt | pacman | brew`
- `DOTFILES_SYSTEM_TYPE`: read from `~/.config/dotfiles/system-type`

A **system type** is any identifier (`desktop`, `server`, `laptop`,
`htpc`, ...), a lookup key for package and hook lists, nothing more. It's
host-local state, set with `install.sh --system-type` or `dj system-type`,
never tracked, and never guessed from `$DISPLAY` or similar. A type no
`types/` list mentions yet is still valid (it means common-only), but since
that's usually a typo, `dj system-type` asks before persisting it (`--yes`
skips the question). Give a deliberately common-only type an empty,
commented `types/<type>.txt` so it reads as known.

## 4. Shell layer

```
~/.config/shell/   POSIX, sourced by both shells: env, aliases, functions,
                   os/<os>.sh, host/<hostname>.sh, secrets.sh (in that order)
~/.config/bash/    bash-only
~/.config/zsh/     zsh-only
~/.bashrc ~/.zshrc tiny loaders
~/.zshenv          skip_global_compinit=1 (see below)
```

`shell-consolidate.sh` creates this on a fresh machine (or migrates an
existing `.bashrc`/`.zshrc` into the shell-specific init). Anything both
shells need goes in the shared layer: a function defined only in the bash
tree silently doesn't exist in zsh.

`~/.config/zsh/completion.zsh` runs `compinit` itself, with `-i` when
there's no terminal (where it can't ask about insecure completion
directories, so it would abort noisily). Debian and Ubuntu's
`/etc/zsh/zshrc` runs a second, plain one first unless
`skip_global_compinit=1` is set by then, i.e. in `~/.zshenv`, so dj sets it
there (`shell-consolidate.sh` on new machines, the
`zsh-skip-global-compinit` migration on existing ones). It means nothing
on other systems.

The one POSIX trap that bites: zsh doesn't word-split an unquoted
parameter. Build argument lists in the positional parameters (`set --`),
never in a string expanded unquoted.

## 5. Packages

Your lists, in your repo:

```
~/.config/dj/packages/common.txt          every machine
~/.config/dj/packages/types/<type>.txt    machines of that type
~/.config/dj/packages/hosts/<host>.txt    one machine
```

`install-packages.sh` installs the union, resolving each logical name
through renames: `<logical> <package|SKIP|SYSTEM> [binary]`.

- `SKIP`: no package; a fallback installer `packages/scripts/<name>.sh`
  runs instead (POSIX sh, idempotent, usually into `/usr/local/bin`).
- `SYSTEM`: the OS configuration provides it (a NixOS module, say), so
  it's neither installed nor reported missing.
- third column: the binary to look for when it isn't the logical name.

Renames resolve user-distro, user-manager, then dj's distro, then dj's
manager file (`~/.config/dj/packages/renames/` beats `packages/renames/`),
and fallback installers in `~/.config/dj/packages/scripts/` beat dj's.
`packages/template/` only seeds a fresh machine's `common.txt`.

`git gpg sops age just` are dj's own requirements and always installed:
by `install.sh`, and by the `required-deps` migration on a machine that
never ran it (a `$HOME` copied from another install, say).

## 6. Post-install hooks

For follow-up system state a package install can't express: enabling a
service, a group membership, an `/etc/fstab` line. Lists mirror the
package lists (`~/.config/dj/postinstall/{common,types/,hosts/}`); each
name runs `~/.config/dj/postinstall/<name>.sh` or dj's
`packages/postinstall/<name>.sh`.

Hooks are the **sanctioned place for narrow, explicit sudo writes**
outside `$HOME`, and each owns its idempotence (check `systemctl
is-enabled` before enabling, group membership before `usermod`, ...). They
run from `dj upgrade`, `dj postinstall` and install.sh, never from `dj
sync` (sync stays fast and sudo-free). A missing script warns without
stopping the others.

## 7. Secrets

- Encrypted files (`.enc`) under `~/.private/secrets/` in your repo. Edit
  through sops (`dj secret-edit`), which keeps plaintext out of the
  working tree.
- An encrypted **manifest** maps each one to its destination and mode;
  `dj apply-secrets` decrypts them there, backing up any differing file it
  would overwrite. `dj secret-add` encrypts a file and registers it.
- Your **age key** (`~/.config/sops/age/keys.txt`) is the one credential
  you carry between machines by hand (`install.sh --age-key`, `--sops
  user@host`, a paste, or the fleet module's `dj setup`). `dj rotate`
  re-encrypts everything under a new one.
- `~/.secrets/*.env` files are sourced by `shell/secrets.sh` as shell
  variables, **not exported**: nothing launched from your shell (an
  editor, a build, an agent) inherits secret values. Export the one a tool
  needs on its command line.
- The pre-commit hook rejects plaintext under `.private/secrets/` and runs
  gitleaks if present. It's a backstop: sops editing never writes
  plaintext to the working tree in the first place.

## 8. SSH keys

**No SSH private key is ever distributed.** Each machine generates its own
`~/.ssh/id_ed25519` and publishes only the public half as
`~/.ssh/authorized_keys.d/<hostname>.pub` in your repo.
`authorized-keys.sh` rebuilds `~/.ssh/authorized_keys` from all of them, so
machines trust each other without sharing a key, and revoking one is a
single file removal. Safety: an empty `.d` never truncates an existing
`authorized_keys`, and keys present only there are backed up first.

Never track `~/.ssh/id_ed25519.pub`: it's per machine.

The first private clone needs credentials before anything is restored:
`install.sh --git-key` takes a deploy key for that clone. The
shared-git-key module covers keeping one git-host key on every machine.

## 9. Migrations

install.sh converges, but only where it's re-run, which after day one is
nowhere. When a newer version learns to set up something, every existing
machine silently goes without. A migration is the catch-up.

- One script per migration, `NN-<id>.sh`, answering `desc|check|fix`
  (protocol: `migrations/README.md`). Core ones live in `migrations/`,
  modules' in `modules/<m>/migrations/`, yours in `~/.config/dj/migrations/`.
- **check is a predicate on live state**, not a stored version number, so
  it's right on a machine that was half-fixed by hand or restored from a
  backup. Exit 0 satisfied, 1 pending, 2 not applicable (silent).
- **Auto vs MANUAL.** Auto-fixable only when the repair is local,
  reversible and needs no judgement. Rotating a credential, removing
  software, or choosing between defensible answers is MANUAL: detected
  and explained with the exact commands, never applied by `--fix`.
- **Honest failure.** A repair with no path on this host says so.
- `dj doctor` reports them; `dj migrate --fix` applies; `dj sync` and
  `dj upgrade` close with a one-line report, so a pull that makes a
  machine stale says so right away.

Rule for contributors: an install.sh step that sets up persistent state
needs a matching migration. Ask "if this had landed last year, what would
an older machine be missing, and would anything complain?" If nothing would
complain, it's a migration.

## 10. NixOS

On NixOS the system (packages everyone needs, services, users, sudo,
`/etc`) comes from a flake; dj keeps to `$HOME`.

- Keep the flake in your repo at `~/.config/nixos/` (it travels with
  sync). dj always refers to it as `path:~/.config/nixos`, so it's
  evaluated as a path flake and copied to the world-readable `/nix/store`:
  never put plaintext secrets in it. Per-host system secrets belong in
  sops-nix, which can decrypt with dj's age key.
- The `nixos-flake-applied` migration compares this host's
  `system.build.toplevel` (evaluated, not built) with `/run/current-system`
  and fixes with `sudo nixos-rebuild switch --flake path:...#<host>`. N/A
  off NixOS, without the flake, or when it has no entry for this hostname.
  `dj sync` reports it; `dj upgrade`/`dj postinstall`/install.sh apply it.
- Packages go into your own profile (`nix profile add nixpkgs#<attr>`, no
  sudo) via `renames/nix.txt`. Tools that need a daemon or a group are
  `SYSTEM` there and declared in the flake.
- Fallback installers don't run (they target `/usr/local/bin`, off PATH
  on NixOS) unless marked `# dj-installer: nix-ok`; post-install hooks
  don't run at all, since the next switch would undo their `/etc` edits.

## 11. Modules

Optional features are modules (`modules/<name>/`): recipes, migrations
and bootstrap hooks that do nothing until enabled in
`~/.config/dj/modules.txt` (your repo, so it follows you) or for one
install.sh run with `--module`. A disabled module's migrations don't exist
on that machine. See `modules/README.md`.

## 12. Bootstrap order (install.sh)

1. Detect OS and package manager; install git.
2. Persist `--system-type` (and `--theme`, tmux-theme module).
3. Clone or update `~/.dotfiles`; install dj's own requirements.
4. Install the `--git-key` clone key, if given.
5. Clone the private repo bare (fatal if `--private-repo` was given and
   fails, because silently continuing with an empty repo looks like
   "everything is default"), or init an empty one.
6. Conflict-aware checkout: existing files are identical (removed and
   re-created), symlinks (backed up), or conflicts (per `--on-conflict
   ask|backup|keep|abort`; non-interactive runs must choose).
7. Back up a legacy `~/.tmux.conf*` when `~/.config/tmux/tmux.conf` is
   tracked (tmux loads both).
8. Record `--module`s; seed `common.txt` on a genuinely fresh machine.
9. Pre-commit hook; packages; post-install hooks.
10. Age key; SOPS init; apply secrets; module post-secrets hooks.
11. Shell consolidation; git identity and keys; module finish hooks.

Everything after step 3 touches only the invoking user's `$HOME`, except
package installs and hooks.

## 13. Arguments and `just`

The Justfile sets `positional-arguments`, and recipes read `"$@"`. Without
it, `just` splices arguments into the recipe as text that the recipe's
shell parses again: backticks in a prompt would run, and a value with a
space would split. Never interpolate `{{ARGS}}` into a command.
