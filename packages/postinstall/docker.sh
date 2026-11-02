#!/bin/sh
# Enables/starts the docker service and adds the invoking user to the
# docker group. Pacman's docker package (unlike Debian's docker.io)
# doesn't enable the service on install, and group membership is
# never handled by any package manager. No-op on systems without
# systemd or without a docker group (e.g. plain `brew install docker`
# on macOS, which has neither).
set -eu

command -v docker >/dev/null 2>&1 || { printf '[postinstall:docker] docker not installed; skipping\n' >&2; exit 0; }

if command -v systemctl >/dev/null 2>&1; then
  sudo systemctl enable --now docker
fi

if command -v getent >/dev/null 2>&1 && getent group docker >/dev/null 2>&1; then
  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    sudo usermod -aG docker "$USER"
    printf '[postinstall:docker] added %s to the docker group -- log out/in (or `newgrp docker`) for it to take effect\n' "$USER"
  fi
fi
