---
name: query-config
description: Answer questions about the dotfiles configuration and the current machine's state — what system-type (tier) it's on, what's tracked vs untracked, what's installed vs missing, what a given config does, where files live. Use when the user asks descriptive/inspection questions ("what type/tier am I on?", "what's tracked under ~/.config/git/?", "is pv installed?", "where do my SSH keys come from?").
---

# query-config

A read-only skill: answer accurately about the current state of this
machine and the design in docs/design.md (and the user's own notes in .claude/AGENTS.md, when present). Do not change anything.

## Shell alias note

`dj` and `dot` are shell aliases/functions — **not available in Claude's
non-interactive Bash tool**. Use the full forms when running commands:

| User types | Claude's Bash tool runs |
|---|---|
| `dj <target>` | `~/.dotfiles/bin/dj <target>` (if `dj` is not on PATH yet) |
| `dot <git-cmd>` | `git --git-dir="$HOME/.config.git" --work-tree="$HOME" <git-cmd>` |

When showing the user commands to run themselves, use `dj` and `dot`.

## Sources of truth, in order

1. **docs/design.md** (and **.claude/AGENTS.md**, the user's own notes,
   when present) — authoritative on the
   *design*. Quote it (with section number) for "why is it this way?"
2. **The filesystem** — authoritative on what's *actually* installed and
   tracked right now. Always prefer this over memory for "what is".
3. **`doctor`** — convenient roll-up of OS, package manager, type,
   tool presence, key/perm checks. Run it once at the start of a session
   if the user is asking about overall health.

## Useful commands

| Question | Command (Claude's Bash form) |
|---|---|
| What OS / pkg-mgr / type? | `. ~/.dotfiles/scripts/os-detect.sh; env \| grep DOTFILES_` |
| What type is persisted? | `cat ~/.config/dotfiles/system-type 2>/dev/null \|\| echo "(unset / common-only)"` |
| Overall health | `dj doctor` |
| What's tracked under a path? | `git --git-dir="$HOME/.config.git" --work-tree="$HOME" ls-tree --full-tree -r --name-only HEAD -- <path>` |
| Is file X tracked? | `git --git-dir="$HOME/.config.git" --work-tree="$HOME" ls-files --error-unmatch <path>` (exit 0 = yes) |
| What's untracked under ~/.config that we *could* track? | `dj audit-config -q` |
| How does our X differ from distro default? | `dj config-diff <path>` |
| What packages should be installed on this machine? | `cat ~/.config/dj/packages/common.txt ~/.config/dj/packages/types/$(cat ~/.config/dotfiles/system-type 2>/dev/null).txt ~/.config/dj/packages/hosts/$(hostname -s).txt 2>/dev/null` (personal lists, private repo — see docs/design.md) |
| What's actually installed? | `command -v <tool>` per tool (or run `dj doctor`) |
| What secrets are materialized? | `sops -d ~/.private/secrets/manifest.txt.enc` (decrypts manifest only) |

## Style

- Lead with the direct answer. Then add at most one sentence of context.
- If the answer requires a command the user can run themselves, show
  the command using `dj` / `dot` (their shell aliases). Don't hide it
  behind a tool call when a copy-pasteable one-liner is more useful.
- For "why" questions, cite docs/design.md: e.g. "see the secrets section on
  why we use SOPS+age rather than gpg".

## What not to do

- Don't run `sops -d` on secret payload files unless the user has
  explicitly asked you to inspect a specific secret. The manifest
  itself is fair game.
- Don't make changes. If you find the user is asking "should I add X?",
  answer the question, then hand off to the `install-package` or
  `edit-config` skill if they want to act.
- Don't speculate. If `command -v rg` fails, say so — don't say "rg
  should be installed because it's in common.txt".
