# dj

Bootstrap and maintain all your machines from two git repos: this one,
the engine, and a private one of your own that tracks your dotfiles
in place in `$HOME`, your package lists, and SOPS-encrypted secrets.

```sh
curl -fsSL https://raw.githubusercontent.com/endotronic/dj/main/install.sh \
  | sh -s -- --private-repo git@github.com:you/dotfiles.git --system-type laptop
```

Linux (apt, pacman), NixOS, macOS (brew) and WSL. POSIX sh throughout.

## What you get

- **Your `$HOME` is the work tree.** Config files are tracked where they
  live, in a bare repo; `dot` is git for it. No templates, no apply step.
- **Package lists** per machine type and per host, resolved through
  per-package-manager renames, with fallback installers for tools no
  package manager ships.
- **Secrets** encrypted with SOPS + age in your repo, decrypted to where
  they belong on every machine. The age key is the one thing you carry.
- **Per-machine SSH keys** with shared trust: every machine's public key
  is in your repo, so they can all reach each other, and none of them
  shares a private key.
- **Migrations** that catch an already-set-up machine up to newer dj, so
  old machines don't quietly miss what new ones get.
- **`dj doctor`**, **`dj sync`**, **`dj upgrade`** for daily use.
- **Opt-in modules**: Claude Code integration, opencode, fleet bootstrap
  over SSH, a shared git-host key, a per-machine tmux accent color.

## Starting out (no private repo yet)

```sh
curl -fsSL https://raw.githubusercontent.com/endotronic/dj/main/install.sh | sh
. ~/.bashrc
dj init --remote git@github.com:you/dotfiles.git --commit
dot push -u origin HEAD
dj migrate --fix
```

`install.sh` without `--private-repo` leaves an empty private repo. `dj
init` lays out `~/.config/dj/` (package lists, hook lists, modules.txt) and
the SOPS config, then stages them with your shell config. **Back up
`~/.config/sops/age/keys.txt`**: without it your secrets can't be
decrypted.

## Another machine

```sh
curl -fsSL https://raw.githubusercontent.com/endotronic/dj/main/install.sh \
  | sh -s -- --private-repo git@github.com:you/dotfiles.git \
             --system-type server --sops you@first-machine
```

`--sops user@host` fetches the age key over scp (or pass `--age-key PATH`,
or paste it when asked). With the fleet module, `dj setup user@host` does
all of it from a machine that's already set up.

## Daily

| | |
|---|---|
| `dj sync` | pull dj and your repo, apply secrets, refresh SSH trust, report stale state |
| `dj upgrade` | sync, then install newly listed packages and run post-install hooks |
| `dj doctor` | sanity checks and pending migrations (`--fix` applies them) |
| `dj add PATH` | track a file (`dot commit`, `dot push` as with any repo) |
| `dj secret-add PATH` | encrypt a file into your secrets and register where it goes |
| `dj secret-edit NAME` | edit one in place through sops |
| `dj system-type TYPE` | change which type lists apply here (asks first for a type no list has) |
| `dj module list` | see and enable optional modules |

Your configuration lives in your repo under `~/.config/dj/`:

```
packages/common.txt  types/<type>.txt  hosts/<host>.txt   what to install
packages/renames/<mgr>.txt  packages/scripts/<name>.sh   your own mappings and installers
postinstall/common.txt ...  postinstall/<name>.sh        system follow-ups (sudo)
migrations/NN-<id>.sh                                     your own catch-up repairs
modules.txt                                               enabled modules
AGENTS.md                                                 notes for coding agents (claude module)
```

## Compared to chezmoi

chezmoi renders a source directory into `$HOME`, with templates; dj
tracks `$HOME` in place and branches at runtime instead. If you need
per-OS file contents, native Windows, or password-manager secret backends,
chezmoi is the better fit. dj's angle is everything around the files:
typed package lists, encrypted secrets with destinations, SSH trust across
machines, and migrations that repair old machines.

## More

- [docs/design.md](docs/design.md): the design and the reasons for it
- [modules/](modules/README.md): optional features
- [migrations/](migrations/README.md): writing a migration
- [AGENTS.md](AGENTS.md): working on dj itself

MIT licensed.
