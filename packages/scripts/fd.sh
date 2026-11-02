#!/bin/sh
# On Debian/Ubuntu, fd-find installs as 'fdfind'; create the 'fd' symlink.
set -eu
command -v fd >/dev/null 2>&1 && exit 0

if command -v fdfind >/dev/null 2>&1; then
  sudo ln -sf "$(command -v fdfind)" /usr/local/bin/fd
  exit 0
fi

printf '[fd] fdfind not found; fd-find package may not be installed\n' >&2
exit 1
