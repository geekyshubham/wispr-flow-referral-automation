#!/usr/bin/env bash
# Speak one chunk via TTS while holding Wispr PTT (Right Option by default).
# Usage: dictate-chunk.sh <text> [keycode] [rate]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEXT="${1:?text required}"
KEYCODE="${2:-61}"
RATE="${3:-180}"
HOLD_SWIFT="${SCRIPT_DIR}/hold-key.swift"

# Focus TextEdit so Wispr pastes there
osascript -e 'tell application "TextEdit" to activate' 2>/dev/null || true
sleep 0.3

# Estimate speak duration: ~rate words/min -> seconds per word
WORD_COUNT=$(echo "$TEXT" | wc -w | tr -d ' ')
HOLD_SEC=$(python3 -c "print(max(3, ${WORD_COUNT} * 60 / ${RATE} + 1))")

# Hold PTT and speak in parallel
swift "$HOLD_SWIFT" "$KEYCODE" "$HOLD_SEC" &
HOLD_PID=$!
sleep 0.2
say -r "$RATE" "$TEXT"
wait "$HOLD_PID" 2>/dev/null || true
