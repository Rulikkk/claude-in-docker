#!/usr/bin/env bash
# Run ONE headless Claude Code job and classify the outcome.
#
#   claude-run.sh <prompt-file> [<log-dir>]
#
# Prints `session_id=<uuid>` and `log=<path>` on stdout for the caller to
# capture. Exit codes are the contract:
#
#   0   success
#   10  usage limit / rate limited   -> defer, retry after reset
#   11  auth failure (401)           -> STOP, do not retry, alert a human
#   1   anything else                -> backoff, then fail the job
#
# 401 and 429 both surface as a nonzero exit, so the body is what gets matched.
set -euo pipefail

PROMPT_FILE="${1:?usage: claude-run.sh <prompt-file> [log-dir]}"
LOG_DIR="${2:-${CLAUDE_LOG_DIR:-/data/logs}}"
mkdir -p "$LOG_DIR"

STAMP="$(date -u +%Y%m%dT%H%M%S%3NZ)"
LOG="$LOG_DIR/$STAMP.jsonl"
ERR="$LOG.err"

ARGS=(-p "$(cat "$PROMPT_FILE")"
      --output-format stream-json
      --verbose
      --permission-mode "${CLAUDE_PERMISSION_MODE:-acceptEdits}")

if [ -n "${CLAUDE_ALLOWED_TOOLS:-}" ]; then
  ARGS+=(--allowedTools "$CLAUDE_ALLOWED_TOOLS")
fi
if [ -n "${CLAUDE_RESUME_SESSION:-}" ]; then
  ARGS+=(--resume "$CLAUDE_RESUME_SESSION")
fi

set +e
claude "${ARGS[@]}" >"$LOG" 2>"$ERR"
RC=$?
set -e

SESSION_ID="$(jq -r 'select(.type=="system" and .subtype=="init") | .session_id' "$LOG" 2>/dev/null | head -n1 || true)"
[ -n "$SESSION_ID" ] && echo "session_id=$SESSION_ID"
echo "log=$LOG"

[ $RC -eq 0 ] && exit 0

BLOB="$(cat "$LOG" "$ERR" 2>/dev/null | tr '[:upper:]' '[:lower:]')"

if grep -Eq 'authentication_error|oauth token has expired|invalid authentication|"status":[[:space:]]*401' <<<"$BLOB"; then
  echo "AUTH_FAILED: token revoked or expired" >&2
  exit 11
fi

if grep -Eq 'rate_limit|usage limit|"status":[[:space:]]*429|quota' <<<"$BLOB"; then
  RESET="$(grep -Eo '"resets_?at"[^,}]*|reset[^,}"]{0,40}' <<<"$BLOB" | head -n1 || true)"
  echo "RATE_LIMITED ${RESET:-}" >&2
  exit 10
fi

echo "FAILED rc=$RC (see $ERR)" >&2
exit 1
