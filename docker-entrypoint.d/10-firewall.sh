#!/usr/bin/env bash
# Applies the egress allowlist unless explicitly disabled.
if [ "${ENABLE_FIREWALL:-1}" = "1" ]; then
  /usr/local/bin/init-firewall.sh
else
  echo "[firewall] DISABLED via ENABLE_FIREWALL=0 — container has unrestricted egress" >&2
fi
