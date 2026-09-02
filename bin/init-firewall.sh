#!/usr/bin/env bash
# Default-deny egress with an allowlist, in the spirit of the reference Claude
# Code devcontainer firewall.
#
# Requires cap_add: [NET_ADMIN, NET_RAW]. If those are missing this exits
# nonzero and the container dies, which is deliberate: a container that was
# meant to be locked down should not come up wide open.
#
# Host-level ufw does NOT filter container egress, because Docker inserts its
# own rules ahead of it. This runs inside the netns and does.
#
# Allowlist sources, merged:
#   FIREWALL_ALLOW_DOMAINS   space-separated env var
#   /config/firewall-allow.txt   one domain per line, # comments ok
set -euo pipefail

BASE_DOMAINS="api.anthropic.com console.anthropic.com claude.ai statsig.anthropic.com sentry.io"
DOMAINS="$BASE_DOMAINS ${FIREWALL_ALLOW_DOMAINS:-}"
ALLOW_FILE="${FIREWALL_ALLOW_FILE:-/config/firewall-allow.txt}"

if [ -f "$ALLOW_FILE" ]; then
  DOMAINS="$DOMAINS $(sed 's/#.*//' "$ALLOW_FILE" | tr -s '[:space:]' ' ')"
fi

if ! iptables -L -n >/dev/null 2>&1; then
  echo "[firewall] FATAL: cannot manage iptables. Add cap_add: [NET_ADMIN, NET_RAW]" >&2
  echo "[firewall] or set ENABLE_FIREWALL=0 to accept unrestricted egress." >&2
  exit 1
fi

apply() {
  iptables -F OUTPUT
  ipset destroy allowed 2>/dev/null || true
  ipset create allowed hash:net

  iptables -A OUTPUT -o lo -j ACCEPT
  iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

  local resolved=0
  for d in $DOMAINS; do
    [ -n "$d" ] || continue
    ips="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    if [ -z "$ips" ]; then
      echo "[firewall] WARNING: unresolved $d" >&2
      continue
    fi
    for ip in $ips; do ipset add allowed "$ip" 2>/dev/null || true; done
    resolved=$((resolved + 1))
  done

  # Local compose network, so sidecars stay reachable.
  if [ -n "${FIREWALL_ALLOW_SUBNET:-}" ]; then
    for net in ${FIREWALL_ALLOW_SUBNET}; do
      iptables -A OUTPUT -d "$net" -j ACCEPT
    done
  fi

  iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -m set --match-set allowed dst -j ACCEPT
  iptables -P OUTPUT DROP

  echo "[firewall] egress restricted; $resolved domains allowed"
}

apply

# Endpoints behind CDNs rotate addresses. A container that stays up for days
# will otherwise start failing on an allowlist that was correct at boot.
if [ "${FIREWALL_REFRESH_SECONDS:-0}" -gt 0 ] 2>/dev/null; then
  (
    while sleep "$FIREWALL_REFRESH_SECONDS"; do
      apply >/dev/null 2>&1 || echo "[firewall] refresh failed" >&2
    done
  ) &
  echo "[firewall] refreshing every ${FIREWALL_REFRESH_SECONDS}s"
fi
