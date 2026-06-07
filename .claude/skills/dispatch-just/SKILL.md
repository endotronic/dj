---
name: dispatch-just
description: Map natural-language intent in this repo to the right `just` verb (or sequence) and run it. Use when the user expresses an operation in their own words ("pull latest", "rebuild secrets", "rerun installs", "check things are sane", "see what's different from upstream") rather than naming a `just` target directly.
---

# dispatch-just

This repo's daily-use surface is `.dotfiles/Justfile`, invoked via the
`dj` shell function. Most of the time the user wants to *do* something
and doesn't care to remember the exact verb. Translate the intent and run it.

## Shell alias note

`dj` and `dot` are shell aliases/functions — **not available in Claude's
non-interactive Bash tool**. Use the full forms when running commands:

| User types | Claude's Bash tool runs |
|---|---|
| `dj <target>` | `JUST_JUSTFILE="$HOME/.dotfiles/Justfile" just <target>` |
| `dot <git-cmd>` | `git --git-dir="$HOME/.config.git" --work-tree="$HOME" <git-cmd>` |

When telling the user what to run next, use `dj` and `dot` — those work
in their interactive shell.

## Intent → command

| Intent | Target |
|---|---|
| "pull latest", "sync", "update from remote" | `sync` |
| "pull and install anything new" | `upgrade` |
| "install / re-install packages" | `install-packages` |
| "stage <file>", "track <file>" | `add <path>` (or full `git --git-dir=...` if multi-arg quoting matters) |
| "what's staged / status" | `status` |
| "commit" | `commit` (interactive editor) or full `git --git-dir=...` for one-liners |
| "push" | `push` |
| "diff", "what's changed" | `diff` |
| "edit a secret named X" | `secret-edit X` |
| "rebuild / apply secrets" | `apply-secrets` |
| "set type/tier to desktop", "switch type to <anything>" | `system-type <type\|none>` (any identifier — it's a lookup key for `~/.config/dj/packages/types/<type>.txt`; does NOT install — follow with `upgrade` if they want install too) |
| "first-time SOPS setup" | `sops-init` |
| "sanity check", "is everything ok" | `doctor` |
| "what's under ~/.config that we could track?" | `audit-config` (or `-q` for newline list) |
| "diff <path> against the distro/Omarchy default" | `config-diff <path>` |
| "snapshot / refresh claude credentials" | `claude-creds-snapshot` |
| "open claude here in dotfiles context" | `claude` |
| "run the tests" | `test` |

## Rules

1. **Run `JUST_JUSTFILE="$HOME/.dotfiles/Justfile" just --list` first** if
   the user's intent doesn't cleanly match the table above — the Justfile
   may have grown a recipe this skill hasn't seen.
2. **Confirm before destructive verbs.** `commit`, `push`, and anything
   that mutates the remote needs explicit user approval per CLAUDE.md §9.
   `sync` is safe (rebase + rematerialize secrets).
3. **Don't chain verbs the user didn't ask for.** "Sync" means `sync`,
   not `sync && upgrade && doctor`. Each verb is intentionally small.
4. **Show exit status and any warnings.** If `doctor` returns non-zero,
   surface the failing checks; don't bury them.
5. **If the user's request implies a *change* the Justfile doesn't
   cover** (e.g. "install pv", "edit my starship prompt"), this is the
   wrong skill — hand off to `install-package` or `edit-config`.
