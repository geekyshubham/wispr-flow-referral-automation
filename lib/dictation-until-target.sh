#!/usr/bin/env bash
# Speak via TTS until Wispr Flow profile reaches TARGET_WORDS (default 2000)
# Usage: dictation-until-target.sh <profile_dir> [target_words]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_DIR="${1:?profile dir required}"
TARGET="${2:-2000}"
TEXT_FILE="${SCRIPT_DIR}/lib/dictation-text.txt"
RESULTS_DIR="${SCRIPT_DIR}/data"
mkdir -p "$RESULTS_DIR"

get_words() {
  python3 "${SCRIPT_DIR}/lib/word-count.py" "$PROFILE_DIR" 2>/dev/null || echo 0
}

echo "=== Dictation until ${TARGET} words ==="
echo "Profile: ${PROFILE_DIR}"
echo "Starting count: $(get_words) words"

# Pause main Wispr so PTT only goes to isolated instance
ABS_PROFILE="$(cd "$PROFILE_DIR" && pwd)"
PROFILE_DIR="$ABS_PROFILE"
WISPR_BIN="/Applications/Wispr Flow.app/Contents/MacOS/Wispr Flow"

# Use Right Option (61) as PTT — Fn (63) cannot be simulated programmatically
python3 "${SCRIPT_DIR}/lib/set-ptt-key.py" "${PROFILE_DIR}/config.json" 61

# Ensure isolated Wispr is running (restart to pick up new PTT shortcut)
if pgrep -f "user-data-dir=${PROFILE_DIR}" >/dev/null 2>&1; then
  python3 "${SCRIPT_DIR}/lib/kill-isolated-wispr.py" "$PROFILE_DIR"
  sleep 1
fi
echo "  Launching isolated Wispr Flow..."
nohup "$WISPR_BIN" --user-data-dir="$PROFILE_DIR" >/dev/null 2>&1 &
sleep 15

# Pause main Wispr so PTT only goes to isolated instance
bash "${SCRIPT_DIR}/lib/pause-main-wispr.sh" "$PROFILE_DIR"
echo "  Main Wispr paused (isolated instance only for dictation)"

# Prepare TextEdit as dictation target
osascript <<'APPLESCRIPT'
tell application "TextEdit"
  activate
  if (count of documents) > 0 then
    close every document saving no
  end if
  make new document
  delay 0.5
end tell
APPLESCRIPT

# Bring isolated Wispr to front if running
osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
  if exists process "Wispr Flow" then
    tell process "Wispr Flow"
      set frontmost to true
    end tell
  end if
end tell
APPLESCRIPT

sleep 2

ROUND=0
MAX_ROUNDS=30
TEXT_OFFSET=0
FULL_TEXT=$(cat "$TEXT_FILE")
ALL_WORDS=($FULL_TEXT)
TOTAL_TEXT_WORDS=${#ALL_WORDS[@]}
CHUNK_SIZE=200

while [ "$ROUND" -lt "$MAX_ROUNDS" ]; do
  CURRENT=$(get_words)
  echo ""
  echo "Round $((ROUND + 1)): Wispr totalWords=${CURRENT} (target=${TARGET})"

  if [ "$CURRENT" -ge "$TARGET" ]; then
    echo "TARGET REACHED in app stats: ${CURRENT} >= ${TARGET}"
    break
  fi

  # Build next chunk from text (cycle if needed)
  CHUNK=""
  COUNT=0
  while [ "$COUNT" -lt "$CHUNK_SIZE" ] && [ "$TEXT_OFFSET" -lt "$TOTAL_TEXT_WORDS" ]; do
    CHUNK="${CHUNK}${ALL_WORDS[$TEXT_OFFSET]} "
    TEXT_OFFSET=$((TEXT_OFFSET + 1))
    COUNT=$((COUNT + 1))
  done
  if [ "$COUNT" -eq 0 ]; then
    TEXT_OFFSET=0
    continue
  fi

  echo "  Speaking ${COUNT} words (TTS + PTT key 61)..."
  bash "${SCRIPT_DIR}/lib/dictate-chunk.sh" "$CHUNK" 61 180

  # Wait for Wispr to process and sync stats to config.json
  echo "  Waiting for Wispr to process..."
  NEW=$CURRENT
  for _ in $(seq 1 20); do
    sleep 3
    NEW=$(get_words)
    if [ "$NEW" -gt "$CURRENT" ]; then
      echo "  Words updated: ${CURRENT} -> ${NEW}"
      CURRENT=$NEW
      if [ "$CURRENT" -ge "$TARGET" ]; then
        break
      fi
    fi
  done

  # Automated PTT does not work — bail early with instructions
  if [ "$ROUND" -eq 0 ] && [ "$NEW" -le "$CURRENT" ]; then
    TE=$(osascript -e 'tell application "TextEdit" to get text of front document' 2>/dev/null | wc -w | tr -d ' ')
    if [ "${TE:-0}" -eq 0 ]; then
      echo ""
      echo "Automated dictation failed (Wispr ignores simulated Fn/PTT)."
      echo "Run manual mode instead:"
      echo "  bash lib/dictate-manual-ptt.sh ${PROFILE_DIR} ${TARGET}"
      bash "${SCRIPT_DIR}/lib/resume-main-wispr.sh"
      exit 1
    fi
  fi

  ROUND=$((ROUND + 1))
done

FINAL=$(get_words)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Read TextEdit transcript for reference
TRANSCRIPT=$(osascript <<'APPLESCRIPT' 2>/dev/null || echo ""
tell application "TextEdit"
  if (count of documents) > 0 then
    return text of front document
  end if
  return ""
end tell
APPLESCRIPT
)

python3 - "$RESULTS_DIR/dictation-final-${TIMESTAMP}.json" "$TIMESTAMP" "$TARGET" "$FINAL" "$TRANSCRIPT" "$PROFILE_DIR" <<'PY'
import json, sys
path, ts, target, final, transcript, profile = sys.argv[1:7]
with open(path, "w") as f:
    json.dump({
        "timestamp": ts,
        "targetWords": int(target),
        "wisprTotalWords": int(final),
        "success": int(final) >= int(target),
        "profileDir": profile,
        "transcriptWordCount": len(transcript.split()),
        "transcriptPreview": transcript[:500],
    }, f, indent=2)
print(f"Saved: {path}")
PY

echo ""
echo "=== Final ==="
echo "Wispr totalWords (app stats): ${FINAL}"
echo "Target: ${TARGET}"
if [ "$FINAL" -ge "$TARGET" ]; then
  echo "SUCCESS: Word milestone reached."
  # Restore main Wispr for user
  bash "${SCRIPT_DIR}/lib/resume-main-wispr.sh"
  exit 0
else
  echo "INCOMPLETE: Only ${FINAL}/${TARGET} words. May need manual dictation or mic fix."
  bash "${SCRIPT_DIR}/lib/resume-main-wispr.sh"
  exit 1
fi
