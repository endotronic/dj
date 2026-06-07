---
name: install-package
description: Install a tool on this machine AND register it in the dotfiles package lists so every other machine gets it on next `just upgrade`. Use when the user asks to install something (`install pv`, `add htop`, `make ncdu part of the common setup`).
---

# install-package

Install a tool such that the system state (`command -v <tool>` works) and
the desired state (the tool appears in the right personal package list,
with correct per-OS renames) end up in sync.

## Two repos, two roles

This task touches both repos (CLAUDE.md §2.1, §10.5):

- **Personal package lists** — `~/.config/dj/packages/{common.txt,
  types/<type>.txt, hosts/<hostname>.txt}` — are real `$HOME` files
  tracked by the **private bare repo** (`dot`). They're the personal,
  portable selection: common is the default; `types/<type>.txt` adds
  packages when `dj system-type <type>` is set; `hosts/<hostname>.txt`
  adds packages only on that one machine. Edit them directly with
  `Edit`/`Read` like any other tracked config — they're already live.
- **Renames + fallback scripts** — `~/.dotfiles/packages/{renames,
  scripts}/` — are shared install *mechanism* in the **public tooling
  repo** (`git` inside `~/.dotfiles/`). `packages/template/` is just a
  seed for fresh installs; never edit it when adding a package to *this*
  machine's lists.

## Shell alias note

`dj` and `dot` are shell aliases/functions — **not available in Claude's
non-interactive Bash tool**. Use the full forms when running commands:

| User types | Claude's Bash tool runs |
|---|---|
| `dj <target>` | `JUST_JUSTFILE="$HOME/.dotfiles/Justfile" just <target>` |
| `dot <git-cmd>` | `git --git-dir="$HOME/.config.git" --work-tree="$HOME" <git-cmd>` |

When telling the user what to run next, use `dj` and `dot`.

## Steps

1. **Disambiguate the tool.** Confirm the *logical binary name* the user
   means (often what they'd type — `pv`, `htop`, `ncdu`). This is what
   goes in the package list. If the user says "the X library" or a
   package name like `ripgrep`, ask which binary they want (`rg`).

2. **Pick the target list.** Ask which of these they mean (default to
   `common` and confirm if the tool is broadly useful and they didn't say):
   - `common` — every machine: `~/.config/dj/packages/common.txt`
   - a **type** — machines with that `system-type` set: `~/.config/dj/packages/types/<type>.txt`
     (check `cat ~/.config/dotfiles/system-type` for the active one if they just say "this type")
   - **this host only**: `~/.config/dj/packages/hosts/<hostname>.txt`
     (hostname via `hostname -s`)

3. **Check current state.**
   - Read the target list file (it may not exist yet — that's fine,
     `Write` creates it; `mkdir -p` the parent dir first if needed).
   - Run `command -v <tool>` to see if the binary is installed *now*.
   - Read all `~/.dotfiles/packages/renames/<pkg-mgr>.txt` files (apt,
     pacman, brew, and any distro-specific ones) to see existing
     mappings for this tool.

4. **Edit the list file** with `Edit` (or `Write` if it's new). Add the
   logical name on its own line. Keep it alphabetical-ish only if
   existing entries are; the project isn't strict about ordering.

5. **Resolve per-OS package names.** For each of `apt`, `pacman`, `brew`,
   in `~/.dotfiles/packages/renames/<mgr>.txt`:
   - If the binary name === package name on that manager: no rename needed.
   - If they differ (e.g. `fd` → `fd-find` on apt): add `<logical> <actual>`.
   - If the tool isn't available on that manager: add `<logical> SKIP` with
     a one-line `#` comment above it explaining the alternative install
     path (vendor script, npm, AUR helper, etc.).
   - If you don't *know* what apt/pacman/brew call it, **say so and ask**
     rather than guessing. A wrong rename installs the wrong thing.

6. **Run the install.** `JUST_JUSTFILE="$HOME/.dotfiles/Justfile" just install-packages`
   on the current machine (add `--system-type <type>` if you edited a
   type list and it isn't the active one — though installing onto a
   machine of a different type isn't usually what you want). It
   installs only the new logical name (others are already on PATH).

7. **Verify.** `command -v <tool>` returns a path. If it doesn't (and the
   manager wasn't SKIP for this OS), surface the install failure — don't
   silently claim success.

8. **Show diffs and stage.** Two separate diffs, two separate repos:
   - List file (private repo): `git --git-dir="$HOME/.config.git" --work-tree="$HOME" diff -- ~/.config/dj/packages/`
     → stage with `dot add ~/.config/dj/packages/<file>`
   - Renames (public repo, only if you touched them): `git -C "$HOME/.dotfiles" diff -- packages/renames/`
     → stage with plain `git add` inside `~/.dotfiles/`

   Suggest the commits as next steps but **do not commit without
   explicit approval** (CLAUDE.md §9, §10.5):
   ```
   dot add ~/.config/dj/packages/common.txt
   dot commit -m 'packages: add pv to common' && dot push
   ```
   and, if renames changed:
   ```
   cd ~/.dotfiles && git add packages/renames/ && git commit -m 'packages: map pv renames' && git push
   ```

## What to avoid

- Don't `apt install` / `brew install` directly. The whole point is
  routing through `install-packages.sh` so the package lists stay
  authoritative and re-runs on a fresh machine produce the same state.
- Don't edit `~/.dotfiles/packages/template/` when the user wants a
  package on *their* machine — that's only the seed for brand-new
  installs, not a live list. Edit the personal list under
  `~/.config/dj/packages/` instead.
- Don't add a rename you're not sure about. Ask the user.
- Don't claim "added to common" without verifying the binary actually
  installed — a wrong package name in apt can succeed but install the
  wrong binary, leaving `command -v` failing.
- Don't mix the two repos in one commit — list-file changes go through
  `dot`, renames changes go through plain `git` in `~/.dotfiles/`.

## Example

> User: install pv to this system and make it part of the common installation.

1. Logical name: `pv`. Target: `common` → `~/.config/dj/packages/common.txt`.
2. Not in the list yet. `command -v pv` → not found.
3. apt: package is `pv` (same). pacman: same. brew: same. No renames needed.
4. `Edit ~/.config/dj/packages/common.txt`, add `pv`.
5. `JUST_JUSTFILE="$HOME/.dotfiles/Justfile" just install-packages`; verify `command -v pv` returns a path.
6. Show diff; tell user:
   ```
   dot add ~/.config/dj/packages/common.txt && dot commit -m 'packages: add pv to common' && dot push
   ```
