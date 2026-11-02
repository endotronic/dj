---
name: edit-config
description: Modify a tracked (or to-be-tracked) configuration file according to a user goal stated in natural language ("tighten the starship prompt", "make hyprland gaps smaller", "add an alias for kc"). Handles the dotfiles-specific workflow: prefer override hooks, diff against distro default, stage via `dot add`, leave commit/push to the user.
---

# edit-config

Apply a config change in a way that respects the project's design rules
(see docs/design.md). The user wants a *result* ("smaller
hyprland gaps"); your job is to make the right edit in the right place
and surface what changed.

## Shell alias note

`dj` and `dot` are shell aliases/functions — **not available in Claude's
non-interactive Bash tool**. Use the full forms when running commands:

| User types | Claude's Bash tool runs |
|---|---|
| `dj <target>` | `~/.dotfiles/bin/dj <target>` (if `dj` is not on PATH yet) |
| `dot <git-cmd>` | `git --git-dir="$HOME/.config.git" --work-tree="$HOME" <git-cmd>` |

When telling the user what to run next, use `dj` and `dot`.

## Workflow

1. **Locate the config.** Use `Read` / `grep` to find the actual file
   under `~/.config/`, `~/.gitconfig`, `~/.tmux.conf`, etc. If multiple
   files could be edited, ask the user which one they mean.

2. **Check the override-hook rule.** If the path is under
   `~/.config/{hypr,waybar,walker,alacritty,kitty,ghostty,mako,omarchy}/`
   on an Omarchy host (detect: `/etc/os-release` mentions Arch *and*
   `~/.local/share/omarchy/` exists), **invoke the `omarchy` skill if one is available**
   instead of editing the file directly. Omarchy's own tooling makes this
   mandatory.

3. **Diff against the upstream default first** when relevant. Run
   `dj config-diff <path>`
   to see how the current file differs from the distro default.
   This tells you whether the file is already a divergence (safe to edit)
   or matches upstream (consider whether an override fragment is better).

4. **Make the edit** with `Edit` (not `Write`) when modifying an
   existing file. Keep the change minimal — don't reformat, don't
   reorder unrelated sections, don't "improve" surrounding code.

5. **Verify syntactically** if a quick check exists:
   - shell snippets: `sh -n <file>` or `bash -n <file>`
   - toml: open and re-read; structural typos usually visible
   - hyprland: no built-in linter; rely on user to reload

6. **Show what changed.** Run `git --git-dir="$HOME/.config.git" --work-tree="$HOME" diff -- <path>`
   for bare-repo-tracked files. Tell the user *concretely* what the
   change does in one sentence.

7. **Stage but don't commit.** If the file isn't tracked yet, use
   `git --git-dir="$HOME/.config.git" --work-tree="$HOME" add <path>`.
   Mention `dot commit` / `dot push` as the next steps for the user.
   Never commit without explicit approval.

## Special cases

- **Tool-specific knowledge.** For Starship, Hyprland, etc., apply the
  tool's idiomatic config style. If a dedicated skill for that tool
  exists in `.claude/skills/`, it takes precedence over this generic
  workflow.
- **Shared shell layer (`~/.config/shell/`).** POSIX only — no `[[`,
  `local`, arrays, or `function name()`. Those go in `~/.config/bash/`
  or `~/.config/zsh/` instead. (docs/design.md)
- **Type-specific binaries in shell init.** Any new line that calls a
  binary which might not be installed (e.g. `eval "$(zoxide init bash)"`)
  must guard with `command -v <tool> >/dev/null 2>&1 && ...`. The same
  file ships to every machine regardless of system-type.
- **Don't touch `~/.config/dotfiles/system-type`.** It's host-local
  state (docs/design.md). If the user wants to change it, tell them to
  run `dj system-type <type>`. (For adding/removing packages, hand off
  to `install-package` instead — that edits
  `~/.config/dj/packages/{common,types/<type>,hosts/<host>}.txt`.)

## What to avoid

- Don't replace an upstream file wholesale when an override fragment
  would do (docs/design.md).
- Don't auto-format or rewrite surrounding code "while you're in there".
- Don't commit. Stage, show diff, hand back.
