# Working on dj

This file is for agents (and people) changing **this repository**: the public
engine. It says nothing about any particular user's machines or private repo,
and nothing user-specific belongs in it.

## Norms

- **POSIX `sh`** for everything under `scripts/`, `packages/`, `install.sh`
  and `bin/`: these run on fresh machines, under `dash`. No `[[`, `local`,
  arrays, or `function name()`.
- **Idempotent.** Every script is safe to re-run and converges.
- **Tests with the change.** Every script gets bats coverage in
  `tests/<name>.bats` in the same commit, using the sandbox helpers in
  `tests/test_helper.bash` (isolated `$HOME`, stubbed `sudo` and package
  managers). Run `bats tests/`.
- **Nothing personal.** No usernames, hostnames, domains, or one person's
  services in code, tests or docs. Tests use `alice`, `host1`,
  `example.com`.
- **One home for OS detection:** `scripts/os-detect.sh`.
