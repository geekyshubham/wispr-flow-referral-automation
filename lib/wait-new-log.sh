#!/usr/bin/env bash
# Wait for PATTERN to appear in LOG after AFTER_LINES (1-based count of existing lines).
# Usage: wait-new-log.sh <log> <pattern> <after_lines> [timeout_sec]
set -euo pipefail
LOG="${1:?log}"
PATTERN="${2:?pattern}"
AFTER="${3:?after_lines}"
TIMEOUT="${4:-90}"
touch "$LOG"
for _ in $(seq 1 "$TIMEOUT"); do
  if tail -n +"$((AFTER + 1))" "$LOG" 2>/dev/null | rg -q "$PATTERN"; then
    exit 0
  fi
  sleep 1
done
echo "Timeout waiting for /$PATTERN/ after line ${AFTER} in ${LOG}" >&2
exit 1
