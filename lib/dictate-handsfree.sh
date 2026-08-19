#!/usr/bin/env bash
# Automated dictation via wispr-flow://start-hands-free + BlackHole loopback.
# Does NOT open TextEdit — Wispr counts words from ASR even if paste has nowhere to go.
# Usage: dictate-handsfree.sh <profile_dir> [target_words]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_DIR="${1:?profile dir required}"
TARGET="${2:-2000}"
TEXT_FILE="${SCRIPT_DIR}/lib/dictation-text.txt"
ABS_PROFILE="$(cd "$PROFILE_DIR" && pwd)"
WISPR_BIN="/Applications/Wispr Flow.app/Contents/MacOS/Wispr Flow"
LOG="${SCRIPT_DIR}/data/isolated-wispr.log"
mkdir -p "$(dirname "$LOG")"
touch "$LOG"
chmod +x "${SCRIPT_DIR}/lib/wait-new-log.sh" "${SCRIPT_DIR}/lib/speak-to-blackhole.sh"

get_words() {
  python3 "${SCRIPT_DIR}/lib/word-count.py" "$ABS_PROFILE" 2>/dev/null || echo 0
}

log_lines() {
  wc -l < "$LOG" | tr -d ' '
}

wait_log() {
  local pattern="$1"
  local after="$2"
  local timeout="${3:-90}"
  bash "${SCRIPT_DIR}/lib/wait-new-log.sh" "$LOG" "$pattern" "$after" "$timeout"
}

isolated_running() {
  pgrep -f "user-data-dir=${ABS_PROFILE}" >/dev/null 2>&1
}

launch_isolated() {
  bash "${SCRIPT_DIR}/lib/pause-main-wispr.sh" "$ABS_PROFILE"
  python3 "${SCRIPT_DIR}/lib/set-blackhole-mic.py" "${ABS_PROFILE}/config.json"

  if isolated_running; then
    echo "  Isolated Wispr already running — not relaunching (relaunch overwrites stats)"
  else
    echo "  Launching isolated Wispr..."
    local after
    after=$(log_lines)
    nohup "$WISPR_BIN" --user-data-dir="$ABS_PROFILE" >> "$LOG" 2>&1 &
    echo "  Waiting for NEW helper-ready (after line ${after})..."
    wait_log "Helper service is ready: true" "$after" 120
    echo "  Helper ready"
    sleep 8
  fi

  echo "  Switching mic to BlackHole..."
  local after
  after=$(log_lines)
  open "wispr-flow://switch-mic?mic_name=BlackHole%202ch%20(Virtual)"
  sleep 2
  if tail -n +"$((after + 1))" "$LOG" | rg -q "No audio devices available"; then
    echo "  Audio devices not ready — retrying mic switch in 8s..."
    sleep 8
    after=$(log_lines)
    open "wispr-flow://switch-mic?mic_name=BlackHole%202ch%20(Virtual)"
    sleep 3
  fi
  if ! isolated_running; then
    echo "ERROR: isolated Wispr is not running" >&2
    return 1
  fi
}

start_listening() {
  local after
  after=$(log_lines)
  open "wispr-flow://start-hands-free"
  if wait_log "updateDictationStatus: listening" "$after" 12; then
    echo "  Listening"
    return 0
  fi
  if tail -n +"$((after + 1))" "$LOG" | rg -q "Helper was not ready"; then
    echo "  Helper not ready — waiting 10s and retrying start..."
    sleep 10
    after=$(log_lines)
    open "wispr-flow://start-hands-free"
    if wait_log "updateDictationStatus: listening" "$after" 12; then
      echo "  Listening"
      return 0
    fi
  fi
  echo "  Did not enter listening (see log after line ${after})"
  return 1
}

dictate_phrase() {
  local phrase="$1"
  local rate="${2:-150}"

  # No TextEdit: referral word count comes from ASR history, not paste-into-app.
  if ! start_listening; then
    return 1
  fi
  sleep 1

  bash "${SCRIPT_DIR}/lib/speak-to-blackhole.sh" "$phrase" "$rate"
  sleep 1

  local after
  after=$(log_lines)
  open "wispr-flow://stop-hands-free"
  if wait_log "Text lengths - ASR:" "$after" 40; then
    tail -n +"$((after + 1))" "$LOG" | rg "Text lengths - ASR:" | tail -1
    return 0
  fi
  echo "  No ASR result after stop"
  return 1
}

echo "=== Hands-free dictation ==="
echo "Profile: ${PROFILE_DIR}"
echo "Starting: $(get_words) words (target ${TARGET})"

launch_isolated

PHRASES_FILE=$(mktemp -t wispr-phrases)
python3 - "$TEXT_FILE" "$PHRASES_FILE" <<'PY'
import sys
words = open(sys.argv[1]).read().split()
size = 25
phrases = [" ".join(words[i:i+size]) for i in range(0, len(words), size)]
open(sys.argv[2], "w").write("\n".join(p for p in phrases if p.strip()))
PY
PHRASE_COUNT=$(wc -l < "$PHRASES_FILE" | tr -d ' ')

ROUND=0
STALL=0
while [ "$ROUND" -lt 120 ]; do
  CURRENT=$(get_words)
  echo ""
  echo "Round $((ROUND + 1)): totalWords=${CURRENT} / ${TARGET}"
  if [ "$CURRENT" -ge "$TARGET" ]; then
    echo "TARGET REACHED"
    break
  fi

  INDEX=$(( ROUND % PHRASE_COUNT + 1 ))
  PHRASE=$(sed -n "${INDEX}p" "$PHRASES_FILE")
  [ -z "$PHRASE" ] && break

  BEFORE=$CURRENT
  echo "  Phrase (${INDEX}/${PHRASE_COUNT}): ${PHRASE:0:70}..."
  dictate_phrase "$PHRASE" 150 || true

  AFTER=$(get_words)
  DELTA=$((AFTER - BEFORE))
  echo "  Result: ${BEFORE} -> ${AFTER} (+${DELTA})"

  if [ "$DELTA" -le 0 ]; then
    STALL=$((STALL + 1))
    echo "  No progress (stall ${STALL}/8) — stopping leftover session, retry"
    open "wispr-flow://stop-hands-free" 2>/dev/null || true
    sleep 8
    if [ "$STALL" -ge 8 ]; then
      echo "  Too many stalls. Last log:"
      tail -20 "$LOG"
      break
    fi
  else
    STALL=0
  fi

  ROUND=$((ROUND + 1))
done

rm -f "$PHRASES_FILE"
FINAL=$(get_words)
echo ""
echo "=== Final: ${FINAL} / ${TARGET} words ==="
[ "$FINAL" -ge "$TARGET" ]
