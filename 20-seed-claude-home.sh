#!/usr/bin/env bash
# Copies editable config into the Claude home directory on every start, so
# CLAUDE.md and settings.json can be changed with a restart rather than a
# rebuild. Credentials and session history in that directory are left alone.
SEED_DIR="${CLAUDE_SEED_DIR:-/config/claude-home}"
if [ -d "$SEED_DIR" ]; then
  for f in CLAUDE.md settings.json; do
    if [ -f "$SEED_DIR/$f" ]; then
      cp "$SEED_DIR/$f" "/home/node/.claude/$f"
      chown node:node "/home/node/.claude/$f"
      echo "[seed] $f"
    fi
  done
fi
