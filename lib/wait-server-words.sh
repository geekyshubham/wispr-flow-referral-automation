#!/usr/bin/env bash
# Wait until Wispr SERVER word count (referral source of truth) reaches TARGET.
# Isolated instance must stay running so /history/upload can retry.
# Usage: wait-server-words.sh <profile_dir> [target_words]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/env.sh"
PROFILE_DIR="${1:?profile dir required}"
TARGET="${2:-2100}"
LOG="${SCRIPT_DIR}/data/isolated-wispr.log"
ABS_PROFILE="$(cd "$PROFILE_DIR" && pwd)"
TIMEOUT_SEC="${WAIT_SERVER_TIMEOUT:-900}"
START=$(date +%s)

echo "=== Waiting for SERVER total_words >= ${TARGET} ==="
echo "  (local cache does not count for referrals)"

isolated_running() {
  pgrep -f "user-data-dir=${ABS_PROFILE}" >/dev/null 2>&1
}

server_words() {
  python3 "${SCRIPT_DIR}/lib/fetch-server-stats.py" --quiet "$ABS_PROFILE" 2>/dev/null || echo -1
}

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START))
  if [ "$ELAPSED" -ge "$TIMEOUT_SEC" ]; then
    echo "TIMEOUT after ${ELAPSED}s waiting for server words"
    python3 "${SCRIPT_DIR}/lib/fetch-server-stats.py" "$ABS_PROFILE" 2>/dev/null || true
    python3 "${SCRIPT_DIR}/lib/parse-remote-words.py" "$LOG" 2>/dev/null || true
    exit 1
  fi

  if ! isolated_running; then
    echo "  Isolated Wispr is not running — cannot upload. Aborting wait."
    exit 1
  fi

  SW=$(server_words)
  LOCAL=$(python3 "${SCRIPT_DIR}/lib/word-count.py" "$ABS_PROFILE" 2>/dev/null || echo 0)
  PARSE=$(python3 "${SCRIPT_DIR}/lib/parse-remote-words.py" "$LOG" 2>/dev/null || echo '{}')
  echo "  t=${ELAPSED}s  server=${SW}  local=${LOCAL}  log=${PARSE}"

  if [ "$SW" -ge "$TARGET" ] 2>/dev/null; then
    echo "SERVER TARGET REACHED: ${SW} >= ${TARGET}"
    exit 0
  fi

  if echo "$PARSE" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('saw_503') else 1)" 2>/dev/null; then
    if tail -n 80 "$LOG" | grep -F -q "Too many concurrent requests"; then
      echo "  503 cooldown — sleeping 45s"
      sleep 45
      continue
    fi
  fi

  sleep 15
done
