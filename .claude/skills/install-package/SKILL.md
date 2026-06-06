---
name: install-package
description: Install a tool on this machine AND register it in the dotfiles package lists so every other machine gets it on next `just upgrade`. Use when the user asks to install something (`install pv`, `add htop`, `make ncdu part of the common setup`).
---

# install-package

Install a tool such that the system state (`command -v <tool>` works) and
the desired state (the tool appears in `packages/{common,desktop,server}.txt`
with correct per-OS renames) end up in sync.

## Shell alias note

`dj` and `dot` are shell aliases/functions — **not available in Claude's
non-interactive Bash tool**. Use the full forms when running commands:

| User types | Claude's Bash tool runs |
|---|---|
| `dj <target>` | `JUST_JUSTFILE="$HOME/.dotfiles/Justfile" just <target>` |
| `dot <git-cmd>` | `git --git-dir="$HOME/.dotfiles.git" --work-tree="$HOME" <git-cmd>` |

When telling the user what to run next, use `dj` and `dot`.

## Steps

1. **Disambiguate the tool.** Confirm the *logical binary name* the user
   means (often what they'd type — `pv`, `htop`, `ncdu`). This is what
   goes in `packages/<tier>.txt`. If the user says "the X library" or a
   package name like `ripgrep`, ask which binary they want (`rg`).

2. **Pick the tier.** Ask if it's `common` (every machine), `desktop`
   (GUI tier), or `server` (headless tier). If unsure and the tool is
   broadly useful, default to `common` and confirm.

3. **Check current state.**
   - Read `packages/<tier>.txt` to see if the logical name is already there.
   - Run `command -v <tool>` to see if the binary is installed *now*.
   - Read all three `packages/renames/<pkg-mgr>.txt` files to see existing
     mappings for this tool.

4. **Edit the tier file** with `Edit`. Add the logical name on its own line.
   Keep the file alphabetical-ish only if existing entries are; the project
   isn't strict about ordering.

5. **Resolve per-OS package names.** For each of `apt`, `pacman`, `brew`:
   - If the binary name === package name on that manager: no rename needed.
   - If they differ (e.g. `fd` → `fd-find` on apt): add `<logical> <actual>`
     to `packages/renames/<mgr>.txt`.
   - If the tool isn't available on that manager: add `<logical> SKIP` with
     a one-line `#` comment above it explaining the alternative install
     path (vendor script, npm, AUR helper, etc.).
   - If you don't *know* what apt/pacman/brew call it, **say so and ask**
     rather than guessing. A wrong rename installs the wrong thing.

6. **Run the install.** `JUST_JUSTFILE="$HOME/.dotfiles/Justfile" just install-packages`
   on the current machine. It will install only the new logical name
   (others are already on PATH).

7. **Verify.** `command -v <tool>` returns a path. If it doesn't (and the
   manager wasn't SKIP for this OS), surface the install failure — don't
   silently claim success.

8. **Show the diff.** `git --git-dir="$HOME/.dotfiles.git" --work-tree="$HOME" diff -- ~/.dotfiles/packages/`
   so the user sees what changed. Suggest `dot add` / `dot commit` / `dot push`
   as the next steps, but **do not commit without explicit approval**
   (see CLAUDE.md §9).

## What to avoid

- Don't `apt install` / `brew install` directly. The whole point is
  routing through `install-packages.sh` so the package lists stay
  authoritative and re-runs on a fresh machine produce the same state.
- Don't add a rename you're not sure about. Ask the user.
- Don't claim "added to common" without verifying the binary actually
  installed — a wrong package name in apt can succeed but install the
  wrong binary, leaving `command -v` failing.

## Example

> User: install pv to this system and make it part of the common installation.

1. Logical name: `pv`. Tier: `common`. (Confirm with user if not obvious.)
2. `pv` not in `packages/common.txt`. `command -v pv` → not found.
3. apt: package is `pv` (same). pacman: same. brew: same. No renames needed.
4. Edit `packages/common.txt`, add `pv`.
5. `JUST_JUSTFILE="$HOME/.dotfiles/Justfile" just install-packages`; verify `command -v pv` returns a path.
6. Show diff; tell user:
   ```
   dot add ~/.dotfiles/packages/common.txt && dot commit -m 'packages: add pv to common' && dot push
   ```
