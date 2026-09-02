#!/usr/bin/env bash
# Applies /config/mcp-servers.txt: one `claude mcp add ...` command per line,
# exactly as you would type it. Env vars are expanded, so tokens stay in .env
# and out of the file.
#
#   docker compose run --rm console install-mcp-servers.sh
set -euo pipefail

FILE="${1:-${MCP_SERVERS_FILE:-/config/mcp-servers.txt}}"
[ -f "$FILE" ] || { echo "no $FILE, nothing to install"; exit 0; }

while IFS= read -r line; do
  case "$line" in ''|\#*) continue ;; esac
  echo "+ ${line}"
  eval "$line"
done < "$FILE"

echo
claude mcp list
