#!/usr/bin/env bash
# Fast background dictation: large pre-rendered TTS chunks -> BlackHole -> hands-free deeplink.
# Does not open TextEdit, does not change default speakers, does not steal focus.
# Usage: dictate-fast.sh <profile_dir> [target_words]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_DIR="${1:?profile dir required}"
TARGET="${2:-2100}"
TEXT_FILE="${SCRIPT_DIR}/lib/dictation-text.txt"
ABS_PROFILE="$(cd "$PROFILE_DIR" && pwd)"
WISPR_BIN="/Applications/Wispr Flow.app/Contents/MacOS/Wispr Flow"
LOG="${SCRIPT_DIR}/data/isolated-wispr.log"
AUDIO_DIR="${SCRIPT_DIR}/data/tts-cache"
PLAYER="${SCRIPT_DIR}/lib/play-to-device.bin"
CHUNK_WORDS=280
RATE=230
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
  pgrep -f "user-data-dir=${ABS_PROFILE}" >/dev/null 2>&1
}

deeplink() {
  open -g "$1" >/dev/null 2>&1 || true
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
import os, subprocess, sys
text_file, audio_dir, chunk_words, rate, target = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], int(sys.argv[5])
words = open(text_file).read().split()
need = max(target + 400, 2500)
cycled = (words * ((need // max(len(words),1)) + 2))[:need]
n = 0
paths = []
# Only write the index; generate missing aiff lazily so dictation can start immediately.
for i in range(0, len(cycled), chunk_words):
    chunk = " ".join(cycled[i:i+chunk_words])
    path = os.path.join(audio_dir, f"chunk-{n:03d}.aiff")
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
  say -r "$RATE" -o "$path" "$(cat "$stamp")"
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
  sleep 2
  hide_ui
  if tail -n +"$((after + 1))" "$LOG" | rg -q "No audio devices available"; then
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
  if wait_log "updateDictationStatus: listening" "$after" 10; then
    return 0
  fi
  if tail -n +"$((after + 1))" "$LOG" | rg -q "Helper was not ready"; then
    sleep 8
    after=$(log_lines)
    deeplink "wispr-flow://start-hands-free"
    hide_ui
    wait_log "updateDictationStatus: listening" "$after" 10 && return 0
  fi
  return 1
}

play_chunk() {
  "$PLAYER" "BlackHole 2ch" "$1"
}

echo "=== Fast background dictation ==="
echo "Target: ${TARGET}  Profile: ${PROFILE_DIR}"
echo "Starting count: $(get_words)"

ensure_player
prepare_audio
launch_isolated

CHUNKS=()
while IFS= read -r line; do
  [ -n "$line" ] && CHUNKS+=("$line")
done < "$AUDIO_DIR/index.txt"
ROUND=0
STALL=0
while [ "$ROUND" -lt 40 ]; do
  CURRENT=$(get_words)
  echo ""
  echo "Round $((ROUND + 1)): ${CURRENT} / ${TARGET}  (pending uploads: $(pending_uploads), uploaded: $(uploaded_count))"
  if [ "$CURRENT" -ge "$TARGET" ]; then
    PENDING=$(pending_uploads)
    UPLOADED=$(uploaded_count)
    # Wispr skips /history/upload until the batch has 10 rows unless a force-sync interval is running.
    if [ "$PENDING" -ge 10 ] || [ "$UPLOADED" -ge 8 ]; then
      echo "TARGET REACHED (local ${CURRENT}, pending ${PENDING}, uploaded ${UPLOADED})"
      break
    fi
    echo "  Local target met, but Wispr still has ${PENDING} queued (<10). Dictating extra so the batch can upload..."
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
    [ "$STALL" -ge 6 ] && break
    ROUND=$((ROUND + 1))
    continue
  fi

  BEFORE=$CURRENT
  play_chunk "$CHUNK"
  hide_ui

  local_after=$(log_lines)
  deeplink "wispr-flow://stop-hands-free"
  hide_ui
  if wait_log "Text lengths - ASR:" "$local_after" 25; then
    tail -n +"$((local_after + 1))" "$LOG" | rg "Text lengths - ASR:" | tail -1
  else
    echo "  No ASR line (continuing)"
  fi

  AFTER=$(get_words)
  DELTA=$((AFTER - BEFORE))
  echo "  Result: ${BEFORE} -> ${AFTER} (+${DELTA})"
  if [ "$DELTA" -le 0 ]; then
    STALL=$((STALL + 1))
    echo "  Stall ${STALL}/6"
    deeplink "wispr-flow://stop-hands-free"
    sleep 4
    [ "$STALL" -ge 6 ] && break
  else
    STALL=0
    if tail -n 40 "$LOG" | rg -q "Too many concurrent requests"; then
      echo "  History upload 503 — backing off 45s"
      sleep 45
    elif tail -n 30 "$LOG" | rg -q "skipping upload to batch"; then
      echo "  Batch still <10 — continuing (no long pause)"
      sleep 3
    else
      echo "  Pausing 20s so history can upload..."
      sleep 20
    fi
  fi
  ROUND=$((ROUND + 1))
done

FINAL=$(get_words)
echo ""
echo "=== Final: ${FINAL} / ${TARGET} ==="
[ "$FINAL" -ge "$TARGET" ]
