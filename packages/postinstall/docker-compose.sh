#!/bin/sh
# Some packagings of the Docker Compose v2 plugin (notably Debian/
# Ubuntu's docker-compose-v2) only install into a cli-plugins
# directory, never onto PATH -- `docker compose` works, but
# `command -v docker-compose` (and anything still invoking the legacy
# v1 binary name directly) doesn't. Symlink the plugin onto PATH if a
# `docker-compose` command isn't already there. No-op on systems like
# Arch where the package already puts a real binary on PATH.
set -eu

# Overridable (tests); production default is the four real cli-plugins
# dirs Docker scans, in priority order.
plugin_dirs=${DOTFILES_CLI_PLUGINS_DIRS:-"/usr/local/lib/docker/cli-plugins /usr/local/libexec/docker/cli-plugins /usr/lib/docker/cli-plugins /usr/libexec/docker/cli-plugins"}
symlink_dest=${DOTFILES_COMPOSE_SYMLINK_DEST:-/usr/local/bin/docker-compose}

command -v docker-compose >/dev/null 2>&1 && exit 0

for d in $plugin_dirs; do
  if [ -x "$d/docker-compose" ]; then
    sudo ln -sf "$d/docker-compose" "$symlink_dest"
    printf '[postinstall:docker-compose] symlinked %s -> %s\n' "$d/docker-compose" "$symlink_dest"
    exit 0
  fi
done

printf '[postinstall:docker-compose] no docker-compose plugin found in known cli-plugins dirs; skipping\n' >&2
