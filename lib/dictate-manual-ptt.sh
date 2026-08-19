#!/usr/bin/env bash
# Dictate using TTS while YOU hold Wispr PTT (Fn key). Automated PTT cannot trigger Wispr.
# Usage: dictate-manual-ptt.sh <profile_dir> [target_words]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_DIR="${1:?profile dir required}"
TARGET="${2:-2000}"
TEXT_FILE="${SCRIPT_DIR}/lib/dictation-text.txt"
ABS_PROFILE="$(cd "$PROFILE_DIR" && pwd)"
WISPR_BIN="/Applications/Wispr Flow.app/Contents/MacOS/Wispr Flow"

get_words() {
  python3 "${SCRIPT_DIR}/lib/word-count.py" "$ABS_PROFILE" 2>/dev/null || echo 0
}

echo "=== Manual PTT Dictation ==="
bash "${SCRIPT_DIR}/lib/check-status.sh" "$ABS_PROFILE"
echo ""

bash "${SCRIPT_DIR}/lib/pause-main-wispr.sh" "$ABS_PROFILE"

if ! pgrep -f "user-data-dir=${ABS_PROFILE}" >/dev/null 2>&1; then
  echo "Launching isolated Wispr Flow..."
  nohup "$WISPR_BIN" --user-data-dir="$ABS_PROFILE" >> "${SCRIPT_DIR}/data/isolated-wispr.log" 2>&1 &
  sleep 15
fi

osascript <<'APPLESCRIPT'
tell application "TextEdit"
  activate
  if (count of documents) > 0 then close every document saving no
  make new document
end tell
APPLESCRIPT

echo ""
echo "IMPORTANT: Wispr ignores simulated key presses."
echo "  1. Click TextEdit (already open)"
echo "  2. When prompted, HOLD the Fn key (your Wispr PTT shortcut)"
echo "  3. Keep holding until each chunk finishes speaking"
echo ""
read -r -p "Press Enter when ready to start..."

FULL_TEXT=$(cat "$TEXT_FILE")
mapfile -t ALL_WORDS < <(echo "$FULL_TEXT")
CHUNK_SIZE=150
OFFSET=0
ROUND=0

while [ "$ROUND" -lt 50 ]; do
  CURRENT=$(get_words)
  echo ""
  echo "Round $((ROUND + 1)): local totalWords=${CURRENT} (target=${TARGET})"

  if [ "$CURRENT" -ge "$TARGET" ]; then
    echo "TARGET REACHED"
    break
  fi

  CHUNK=""
  COUNT=0
  while [ "$COUNT" -lt "$CHUNK_SIZE" ] && [ "$OFFSET" -lt "${#ALL_WORDS[@]}" ]; do
    CHUNK="${CHUNK}${ALL_WORDS[$OFFSET]} "
    OFFSET=$((OFFSET + 1))
    COUNT=$((COUNT + 1))
  done
  [ "$COUNT" -eq 0 ] && OFFSET=0 && continue

  echo ""
  echo ">>> HOLD FN NOW <<<  (${COUNT} words, ~$(( COUNT * 60 / 180 )) sec)"
  osascript -e 'tell application "TextEdit" to activate'
  sleep 1
  say -r 180 "$CHUNK"
  sleep 5

  NEW=$(get_words)
  TE=$(osascript -e 'tell application "TextEdit" to get text of front document' 2>/dev/null | wc -w | tr -d ' ')
  echo "  After chunk: totalWords ${CURRENT} -> ${NEW}, TextEdit words: ${TE}"

  if [ "$NEW" -le "$CURRENT" ] && [ "$TE" -eq 0 ] && [ "$ROUND" -ge 2 ]; then
    echo ""
    echo "Still no dictation detected. Check:"
    echo "  - Isolated Wispr shows ${USER:-flowtest64407@emalupe.com}? (not your main Google account)"
    echo "  - Microphone permission granted for Wispr Flow in System Settings"
    echo "  - Only ONE Wispr instance running (main app should be quit)"
    echo "  - Speak into mic yourself instead of TTS if speaker->mic path is too quiet"
    read -r -p "Continue anyway? [y/N] " ans
    [ "${ans,,}" != "y" ] && break
  fi

  ROUND=$((ROUND + 1))
done

FINAL=$(get_words)
echo ""
echo "=== Done ==="
echo "Local totalWords: ${FINAL} / ${TARGET}"
bash "${SCRIPT_DIR}/lib/check-status.sh" "$ABS_PROFILE"

if [ "$FINAL" -ge "$TARGET" ]; then
  bash "${SCRIPT_DIR}/lib/resume-main-wispr.sh"
  exit 0
fi
exit 1
