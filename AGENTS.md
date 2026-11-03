# Working on dj

This file is for agents (and people) changing **this repository**, the
public engine. Design and rationale: `docs/design.md`. How it's used:
`README.md`.

Nothing here is about any particular user. If `.claude/AGENTS.md` exists,
it's the current user's own notes about their machines (linked in from
their private repo by the claude module). Use it for context about their
setup, and never copy anything from it into this repo.

This is the only agent-instructions file. Don't add a `CLAUDE.md` or
`CLAUDE.local.md` beside it: Claude Code reads `AGENTS.md` only where
neither exists.

## Layout

```
install.sh            bootstrap (curl-pipeable)
bin/dj                runs the Justfile from anywhere
Justfile              daily verbs; imports modules/*/<name>.just
scripts/              the mechanisms; scripts/lib/ is sourced, not run
migrations/           core migrations (protocol: migrations/README.md)
packages/             renames, fallback installers, post-install hooks, seed templates
modules/<name>/       opt-in features (modules/README.md)
.claude/skills/       skills for operating a dj setup, loaded by `dj claude`
docs/design.md        the design
tests/                bats suite, one file per script
```

## Rules

- **POSIX `sh`** for everything under `scripts/`, `packages/`,
  `migrations/`, `modules/`, `bin/` and `install.sh`: it runs on fresh
  machines and under `dash`. No `[[`, `local`, arrays, `function name()`.
  In zsh-sourced code, never rely on word splitting of an unquoted
  variable; build lists with `set --`.
- **Idempotent.** Every script converges when re-run; `--fix` twice is a
  no-op the second time.
- **Tests in the same commit.** Every script gets bats coverage in
  `tests/`, using `tests/test_helper.bash`: sandboxed `$HOME`, stubbed
  `sudo` and package managers. Never let a test reach the real `$HOME`,
  network or package manager. Run `bats tests/` (or `dj test`); CI also
  runs on macOS and with zsh installed.
- **Nothing personal.** No usernames, hostnames, domains, or anyone's
  services in code, tests, comments or docs. Use `alice`, `host1`,
  `example.com`. A feature that only makes sense for one setup belongs in
  that user's private repo (`~/.config/dj/...` extension points), not
  here; a feature that's useful but not universal is a module.
- **Outside `$HOME` only through the package manager or a post-install
  hook.** Hooks may use sudo for narrow, explicit, idempotent changes.
- **A new install.sh step that sets up persistent state needs a matching
  migration** (docs/design.md §9). MANUAL if it rotates a credential,
  removes software, or needs a judgement call.
- **OS detection lives in `scripts/os-detect.sh`** (install.sh carries an
  inlined copy because it runs before the clone; keep them in agreement).
- **Never auto-detect the system type**, and never track
  `~/.config/dotfiles/` (host-local state).
- **Recipes read `"$@"`**, never `{{ARGS}}` (docs/design.md §13).
- **Don't commit or push without the maintainer's approval** when working
  as an agent; leave changes staged.
