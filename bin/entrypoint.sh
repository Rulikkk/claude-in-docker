#!/usr/bin/env bash
# Privileged setup, then drop to an unprivileged user and exec CMD.
#
# Extension point: any *.sh in /docker-entrypoint.d/ runs as root, in sorted
# order, before privileges are dropped. Mount your own in to extend without
# forking this image.
set -euo pipefail

log() { echo "[entrypoint] $*"; }

if [ "$(id -u)" = "0" ]; then
  PUID="${PUID:-1000}"
  PGID="${PGID:-1000}"

  # Align the container user with whoever owns the bind-mounted data on the
  # host, so the host and container do not fight over file ownership.
  if [ "$(id -g node)" != "$PGID" ]; then groupmod -o -g "$PGID" node; fi
  if [ "$(id -u node)" != "$PUID" ]; then usermod  -o -u "$PUID" node; fi
  log "running as uid=$PUID gid=$PGID"

  chown -R node:node /home/node/.claude 2>/dev/null || true

  if [ -d /docker-entrypoint.d ]; then
    for f in /docker-entrypoint.d/*.sh; do
      [ -e "$f" ] || continue
      log "hook $f"
      # shellcheck disable=SC1090
      . "$f"
    done
  fi

  log "dropping privileges, exec: $*"
  exec gosu node "$@"
fi

log "already unprivileged, exec: $*"
exec "$@"
