# shared-git-key module

One SSH key, shared by all your machines, for your git host(s) only, kept
separate from each machine's own identity. Enable with
`dj module enable shared-git-key`.

dj's default is per-machine SSH keys: each machine generates its own
`~/.ssh/id_ed25519`, and only the public halves travel (via
`authorized_keys.d`). That's the right model for machine-to-machine SSH.
For your git host it means registering every machine's key with every
forge. This module is the alternative for that one job:

- **One key, `~/.ssh/id_githost`**, kept in your secrets manifest
  (`dj secret-add ~/.ssh/id_githost`), so `dj sync` restores it everywhere.
  Point a tracked `~/.ssh/config` stanza at it for your git host(s):

  ```
  Host github.com git.example.com
    IdentityFile ~/.ssh/id_githost
    IdentitiesOnly yes
  ```

- **First clone.** A fresh machine has neither the manifest nor the
  tracked config yet, so pass the key to install.sh with
  `--git-key PATH`. The fleet module's `dj setup` does this for you.
- **`dotfiles-origin-ssh`** migration: once the key is present, rewrites
  `~/.dotfiles`' origin from https to `git@host:path` so you can push to
  your fork of dj. Only useful if you maintain one; with the upstream repo
  as origin, leave the module off or keep https.
- **`ssh-machine-identity`** migration (MANUAL): flags a machine whose own
  identity key *is* the shared key, which would publish your forge key to
  every other machine as that machine's identity. It prints the rotation
  steps; it never rotates on its own.

The trade-off: a compromised machine leaks the git-host key. Keep its scope
narrow (a repo-scoped deploy key, read-only where a machine only pulls) and
it's one file to rotate.
