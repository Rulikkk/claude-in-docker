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

  # DISABLE_REMOTE_CONTROL is the one switch to flip. On (default, "1") it
  # forces the four vars that Anthropic's own docs name as disabling the
  # feature-flag evaluation Remote Control eligibility depends on:
  # https://code.claude.com/docs/en/remote-control#requirements
  #   DISABLE_TELEMETRY, DO_NOT_TRACK, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC,
  #   DISABLE_GROWTHBOOK
  # DISABLE_AUTOUPDATER and DISABLE_ERROR_REPORTING are NOT on that list and
  # are not touched here; they stay whatever the Dockerfile/environment sets
  # them to, independent of Remote Control.
  if [ "${DISABLE_REMOTE_CONTROL:-1}" = "1" ]; then
    export DISABLE_TELEMETRY=1 DO_NOT_TRACK=1 \
           CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_GROWTHBOOK=1
    log "Remote Control disabled (DISABLE_REMOTE_CONTROL=1)"
  else
    export DISABLE_TELEMETRY=0 DO_NOT_TRACK=0 \
           CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=0 DISABLE_GROWTHBOOK=0
    log "Remote Control enabled (DISABLE_REMOTE_CONTROL=0)"
    # A setup-token credential (claude setup-token) can make model requests
    # but cannot establish a Remote Control session; only a full `/login`
    # (an interactive `claude` run, e.g. via the rc/console service) can.
    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
      log "WARNING: CLAUDE_CODE_OAUTH_TOKEN is set. That is a setup-token" \
          "credential and cannot start a Remote Control session — run" \
          "'claude' interactively (/login) in this container instead."
    fi
  fi

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
