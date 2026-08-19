#!/usr/bin/env bash
# Wait until a NEW "Helper service is ready: true" appears (ignores old log lines).
LOG="${1:?log file}"
TIMEOUT="${2:-90}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AFTER=$(wc -l < "$LOG" | tr -d ' ')
if bash "${SCRIPT_DIR}/wait-new-log.sh" "$LOG" "Helper service is ready: true" "$AFTER" "$TIMEOUT"; then
  echo "Helper ready"
  exit 0
fi
echo "Helper not ready after ${TIMEOUT}s" >&2
exit 1
