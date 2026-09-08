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

# dontAsk denies anything not covered by an explicit permissions.allow rule
# (rather than acceptEdits, which auto-approves edits anywhere under the
# working directory) - the safer default for a job runner explicitly built
# for unattended, untrusted-input use. --permission-prompts none means a
# call that WOULD have needed a human answer is denied immediately instead
# of hanging: nobody is here to answer it. Requires Claude Code v2.1.259+.
ARGS=(-p "$(cat "$PROMPT_FILE")"
      --output-format stream-json
      --verbose
      --permission-mode "${CLAUDE_PERMISSION_MODE:-dontAsk}"
      --permission-prompts none)

if [ -n "${CLAUDE_ALLOWED_TOOLS:-}" ]; then
  ARGS+=(--allowedTools "$CLAUDE_ALLOWED_TOOLS")
fi
if [ -n "${CLAUDE_RESUME_SESSION:-}" ]; then
  # --session-id assigns a fresh id for a NEW conversation; it conflicts
  # with --resume, which continues an existing one under its own id.
  ARGS+=(--resume "$CLAUDE_RESUME_SESSION")
  SESSION_ID="$CLAUDE_RESUME_SESSION"
else
  SESSION_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid;print(uuid.uuid4())")"
  ARGS+=(--session-id "$SESSION_ID")
fi
if [ -n "${CLAUDE_NO_SESSION_PERSISTENCE:-}" ]; then
  ARGS+=(--no-session-persistence)
fi
if [ -n "${CLAUDE_RESTRICTED:-}" ]; then
  ARGS+=(--restricted)
fi
if [ -n "${CLAUDE_MAX_BUDGET_USD:-}" ]; then
  ARGS+=(--max-budget-usd "$CLAUDE_MAX_BUDGET_USD")
fi
if [ -n "${CLAUDE_FALLBACK_MODEL:-}" ]; then
  ARGS+=(--fallback-model "$CLAUDE_FALLBACK_MODEL")
fi
if [ -n "${CLAUDE_MODEL:-}" ]; then
  ARGS+=(--model "$CLAUDE_MODEL")
fi
if [ -n "${CLAUDE_ADD_DIR:-}" ]; then
  ARGS+=(--add-dir "$CLAUDE_ADD_DIR")
fi

set +e
claude "${ARGS[@]}" >"$LOG" 2>"$ERR"
RC=$?
set -e

# Sanity check: the session id claude actually used should match what we
# passed in. Log a warning if the stream's init event disagrees (or is
# missing/malformed) but keep using the pre-generated SESSION_ID for output.
LOGGED_SESSION_ID="$(jq -r 'select(.type=="system" and .subtype=="init") | .session_id' "$LOG" 2>/dev/null | head -n1 || true)"
if [ -n "$LOGGED_SESSION_ID" ] && [ "$LOGGED_SESSION_ID" != "$SESSION_ID" ]; then
  echo "WARNING: logged session_id ($LOGGED_SESSION_ID) != requested ($SESSION_ID)" >&2
fi
echo "session_id=$SESSION_ID"
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
