#!/bin/sh
# shared-git-key module, after secrets are applied (which is when the
# shared key usually lands): make the dj checkout's origin pushable.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
sh "$here/scripts/migrate.sh" --fix --only dotfiles-origin-ssh
