#!/usr/bin/env bash
# Fast background dictation: large pre-rendered TTS chunks -> BlackHole -> hands-free deeplink.
# Does not open TextEdit, does not change default speakers, does not steal focus.
# Usage: dictate-fast.sh <profile_dir> [target_words]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/env.sh"
PROFILE_DIR="${1:?profile dir required}"
TARGET="${2:-2100}"
TEXT_FILE="${SCRIPT_DIR}/lib/dictation-text.txt"
ABS_PROFILE="$(cd "$PROFILE_DIR" && pwd)"
WISPR_APP_PATH="${WISPR_APP_PATH:?Run through wispr-complete-flow to select the isolated runtime}"
WISPR_BIN="${WISPR_BIN_PATH:-${WISPR_APP_PATH}/Contents/MacOS/Wispr Flow}"
LOG="${SCRIPT_DIR}/data/isolated-wispr.log"
AUDIO_DIR="${SCRIPT_DIR}/data/tts-cache"
PLAYER="${SCRIPT_DIR}/lib/play-to-device.bin"
[[ "$TARGET" =~ ^[0-9]+$ ]] && [ "$TARGET" -gt 0 ] || { echo "Invalid word target"; exit 1; }
CHUNK_WORDS=$((TARGET < 280 ? TARGET + 20 : 280))
RATE="${TTS_RATE:-230}"
[[ "$RATE" =~ ^[0-9]+$ ]] && [ "$RATE" -ge 150 ] && [ "$RATE" -le 400 ] || { echo "TTS_RATE must be 150..400"; exit 1; }
mkdir -p "$(dirname "$LOG")" "$AUDIO_DIR"
touch "$LOG"
chmod +x "${SCRIPT_DIR}/lib/wait-new-log.sh" "${SCRIPT_DIR}/lib/hide-isolated.sh"

get_words() {
  python3 "${SCRIPT_DIR}/lib/word-count.py" "$ABS_PROFILE" 2>/dev/null || echo 0
}

pending_uploads() {
  python3 "${SCRIPT_DIR}/lib/parse-remote-words.py" "$LOG" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('last_needs_uploading') or 0)"
}

uploaded_count() {
  python3 "${SCRIPT_DIR}/lib/parse-remote-words.py" "$LOG" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('uploaded_transcripts') or 0)"
}

log_lines() { wc -l < "$LOG" | tr -d ' '; }

wait_log() {
  bash "${SCRIPT_DIR}/lib/wait-new-log.sh" "$LOG" "$1" "$2" "${3:-60}"
}

isolated_running() {
  pgrep -f "^${WISPR_BIN} --user-data-dir=${ABS_PROFILE}" >/dev/null 2>&1
}

deeplink() {
  isolated_running || { echo "ERROR: Isolated app exited; refusing to auto-launch a default profile." >&2; return 1; }
  open -g -a "$WISPR_APP_PATH" "$1" >/dev/null 2>&1
}

hide_ui() {
  bash "${SCRIPT_DIR}/lib/hide-isolated.sh" "$ABS_PROFILE" || true
}

ensure_player() {
  if [ -x "$PLAYER" ]; then return 0; fi
  echo "  Compiling BlackHole player (once)..."
  xcrun swiftc -O "${SCRIPT_DIR}/lib/play-to-device.swift" -o "$PLAYER"
}

prepare_audio() {
  python3 - "$TEXT_FILE" "$AUDIO_DIR" "$CHUNK_WORDS" "$RATE" "$TARGET" <<'PY'
import hashlib, os, sys
text_file, audio_dir, chunk_words, rate, target = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], int(sys.argv[5])
words = open(text_file).read().split()
need = max(target + 400, 2500)
cycled = (words * ((need // max(len(words),1)) + 2))[:need]
n = 0
paths = []
# Only write the index; generate missing aiff lazily so dictation can start immediately.
for i in range(0, len(cycled), chunk_words):
    chunk = " ".join(cycled[i:i+chunk_words])
    key = hashlib.sha256(("aiff-default-v2\0" + rate + "\0" + chunk).encode()).hexdigest()[:16]
    path = os.path.join(audio_dir, f"chunk-{n:03d}-{key}.aiff")
    stamp = path + ".txt"
    open(stamp, "w").write(chunk)
    paths.append(path)
    n += 1
open(os.path.join(audio_dir, "index.txt"), "w").write("\n".join(paths))
print(f"  Plan: {n} chunks x ~{chunk_words} words @ {rate} wpm (lazy TTS)")
PY
}

ensure_chunk() {
  local path="$1"
  local stamp="${path}.txt"
  if [ -s "$path" ] && [ -f "$stamp" ]; then
    return 0
  fi
  echo "  Rendering $(basename "$path")..."
  local temporary
  temporary=$(mktemp -d "${AUDIO_DIR}/.render-XXXXXX")
  if say -r "$RATE" -o "$temporary/speech.aiff" "$(cat "$stamp")"; then
    mv -f "$temporary/speech.aiff" "$path"
    rmdir "$temporary"
  else
    rm -f "$temporary/speech.aiff"
    rmdir "$temporary"
    return 1
  fi
}

launch_isolated() {
  python3 "${SCRIPT_DIR}/lib/set-blackhole-mic.py" "${ABS_PROFILE}/config.json"
  bash "${SCRIPT_DIR}/lib/pause-main-wispr.sh" "$ABS_PROFILE" 2>/dev/null || true

  if isolated_running; then
    echo "  Isolated Wispr already running"
  else
    echo "  Launching isolated Wispr in background..."
    local after
    after=$(log_lines)
    nohup "$WISPR_BIN" --user-data-dir="$ABS_PROFILE" >> "$LOG" 2>&1 &
    wait_log "Helper service is ready: true" "$after" 120
    echo "  Helper ready"
    sleep 6
  fi
  hide_ui

  local after
  after=$(log_lines)
  deeplink "wispr-flow://switch-mic?mic_name=BlackHole%202ch%20(Virtual)"
  if ! wait_log "Switching microphone to: BlackHole 2ch" "$after" 20; then
    echo "ERROR: Cannot confirm BlackHole selection; refusing to record."
    return 1
  fi
  hide_ui
  if tail -n +"$((after + 1))" "$LOG" | grep -F -q "No audio devices available"; then
    sleep 6
    deeplink "wispr-flow://switch-mic?mic_name=BlackHole%202ch%20(Virtual)"
    sleep 2
  fi
}

start_listening() {
  local after
  after=$(log_lines)
  deeplink "wispr-flow://start-hands-free"
  hide_ui
  if wait_log "updateDictationStatus: listening" "$after" 15; then
    return 0
  fi
  if tail -n +"$((after + 1))" "$LOG" | grep -F -q "Helper was not ready"; then
    sleep 8
    after=$(log_lines)
    deeplink "wispr-flow://start-hands-free"
    hide_ui
    wait_log "updateDictationStatus: listening" "$after" 15 && return 0
  fi
  return 1
}

play_chunk() {
  "$PLAYER" "BlackHole 2ch" "$1"
}

echo "=== Fast background dictation ==="
echo "Target: ${TARGET}  Profile: ${PROFILE_DIR}"

ensure_player
launch_isolated
python3 "${SCRIPT_DIR}/lib/verify-runtime-isolation.py" "$ABS_PROFILE" "$(pgrep -f "^${WISPR_BIN} --user-data-dir=${ABS_PROFILE}" | head -1)"
echo "  Isolated: $(pgrep -lf "user-data-dir=${ABS_PROFILE}" | head -1 || echo none)"
START=$(get_words)
INITIAL_SERVER=$(python3 "${SCRIPT_DIR}/lib/fetch-server-stats.py" --quiet "$ABS_PROFILE")
INITIAL_PENDING=$(python3 "${SCRIPT_DIR}/lib/word-count.py" --pending "$ABS_PROFILE")
GAP=$((TARGET - INITIAL_SERVER - INITIAL_PENDING))
CHUNK_WORDS=$((GAP < 260 ? (GAP > 0 ? GAP + 20 : 20) : 280))
prepare_audio
echo "Starting isolated count: ${START}"

CHUNKS=()
while IFS= read -r line; do
  [ -n "$line" ] && CHUNKS+=("$line")
done < "$AUDIO_DIR/index.txt"
ROUND=0
STALL=0
flush_history() {
  echo "  Local target reached; restarting only the isolated test app to flush its real history."
  python3 "${SCRIPT_DIR}/lib/kill-isolated-wispr.py" "$ABS_PROFILE"
  local after pid
  after=$(log_lines)
  nohup "$WISPR_BIN" --user-data-dir="$ABS_PROFILE" >> "$LOG" 2>&1 &
  pid=$!
  wait_log "Helper service is ready: true" "$after" 90
  python3 "${SCRIPT_DIR}/lib/verify-runtime-isolation.py" "$ABS_PROFILE" "$pid"
}
while [ "$ROUND" -lt 40 ]; do
  CURRENT=$(get_words)
  SERVER=$(python3 "${SCRIPT_DIR}/lib/fetch-server-stats.py" --quiet "$ABS_PROFILE" 2>/dev/null || echo -1)
  echo ""
  echo "Round $((ROUND + 1)): local=${CURRENT} server=${SERVER} target=${TARGET} pending=$(pending_uploads) uploaded=$(uploaded_count)"
  if [ "$SERVER" -ge "$TARGET" ] 2>/dev/null; then
    echo "SERVER TARGET REACHED: ${SERVER} >= ${TARGET}"
    exit 0
  fi
  PENDING_WORDS=$(python3 "${SCRIPT_DIR}/lib/word-count.py" --pending "$ABS_PROFILE")
  if [ "$SERVER" -ge 0 ] && [ "$((SERVER + PENDING_WORDS))" -ge "$TARGET" ]; then
    flush_history
    exit 0
  fi
  if [ "$SERVER" -lt 0 ]; then
    echo "ERROR: Cannot verify server progress. Keeping queued history for resume."
    exit 1
  fi

  CHUNK="${CHUNKS[$((ROUND % ${#CHUNKS[@]}))]}"
  ensure_chunk "$CHUNK"
  # Render the next chunk in the background while this one plays
  NEXT="${CHUNKS[$(( (ROUND + 1) % ${#CHUNKS[@]} ))]}"
  if [ -n "$NEXT" ] && [ ! -s "$NEXT" ]; then
    ( ensure_chunk "$NEXT" ) >/dev/null 2>&1 &
  fi
  echo "  Playing $(basename "$CHUNK") ..."

  if ! start_listening; then
    echo "  Failed to start listening"
    STALL=$((STALL + 1))
    deeplink "wispr-flow://stop-hands-free"
    sleep 3
    [ "$STALL" -ge 3 ] && { echo "ERROR: Cannot start dictation"; exit 1; }
    ROUND=$((ROUND + 1))
    continue
  fi

  BEFORE=$CURRENT
  if ! play_chunk "$CHUNK"; then
    deeplink "wispr-flow://stop-hands-free" || true
    echo "ERROR: BlackHole playback failed"
    exit 1
  fi
  hide_ui

  local_after=$(log_lines)
  deeplink "wispr-flow://stop-hands-free"
  hide_ui
  if wait_log "Text lengths - ASR:" "$local_after" 25; then
    tail -n +"$((local_after + 1))" "$LOG" | grep -F "Text lengths - ASR:" | tail -1
  else
    echo "  No ASR line (continuing)"
  fi

  AFTER=$(get_words)
  DELTA=$((AFTER - BEFORE))
  echo "  Result: ${BEFORE} -> ${AFTER} (+${DELTA})"
  if [ "$DELTA" -le 0 ]; then
    STALL=$((STALL + 1))
    echo "  Stall ${STALL}/3"
    [ "$STALL" -ge 3 ] && { echo "ERROR: Dictation made no progress; profile preserved."; exit 1; }
    sleep 2
  else
    STALL=0
  fi
  ROUND=$((ROUND + 1))
done

echo "ERROR: Word target not reached after ${ROUND} rounds; profile preserved."
exit 1
