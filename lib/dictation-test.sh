#!/usr/bin/env bash
# Wispr Flow dictation test: speaks ~2100 words via TTS while holding PTT (Fn key)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEXT_FILE="${SCRIPT_DIR}/lib/dictation-text.txt"
RESULTS_DIR="${SCRIPT_DIR}/data"
OUTPUT_FILE="${RESULTS_DIR}/dictation-output.txt"
mkdir -p "$RESULTS_DIR"

WORD_COUNT=$(wc -w < "$TEXT_FILE" | tr -d ' ')
echo "=== Wispr Flow Dictation Test ==="
echo "Target: ${WORD_COUNT} words"

# Fresh TextEdit doc and clear output file
: > "$OUTPUT_FILE"
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

echo "Speaking into Wispr Flow (Fn/PTT held per chunk)..."
sleep 2

python3 - "$TEXT_FILE" <<'PY'
import subprocess, sys

text = open(sys.argv[1]).read()
words = text.split()
chunk_size = 250
chunks = [' '.join(words[i:i+chunk_size]) for i in range(0, len(words), chunk_size)]

for idx, chunk in enumerate(chunks, 1):
    wc = len(chunk.split())
    print(f"  Chunk {idx}/{len(chunks)} ({wc} words)...", flush=True)
    subprocess.run(['osascript', '-e', 'tell application "System Events" to key down 63'], check=False)
    subprocess.run(['say', '-r', '200', chunk], check=False)
    subprocess.run(['osascript', '-e', 'tell application "System Events" to key up 63'], check=False)
    subprocess.run(['sleep', '1'], check=False)
PY

sleep 8

# Read TextEdit content with fallback
RESULT=$(osascript <<'APPLESCRIPT' 2>/dev/null || echo ""
tell application "TextEdit"
  if (count of documents) > 0 then
    return text of front document
  else
    return ""
  end if
end tell
APPLESCRIPT
)

if [ -z "$RESULT" ]; then
  echo "WARNING: Could not read TextEdit. Check Wispr Flow pasted text manually."
  RESULT=""
fi

echo "$RESULT" > "$OUTPUT_FILE"
RESULT_WORDS=$(echo "$RESULT" | wc -w | tr -d ' ')
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
PCT=$(python3 -c "print(f'{${RESULT_WORDS}/${WORD_COUNT}*100:.1f}')" 2>/dev/null || echo "0")

echo ""
echo "=== Dictation Results ==="
echo "Expected:  ${WORD_COUNT} words"
echo "Got:       ${RESULT_WORDS} words"
echo "Match:     ${PCT}%"
echo "Output:    ${OUTPUT_FILE}"

python3 - "$RESULTS_DIR/dictation-result-${TIMESTAMP}.json" "$TIMESTAMP" "$WORD_COUNT" "$RESULT_WORDS" "$RESULT" <<'PY'
import json, sys
path, ts, expected, got, transcript = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
with open(path, "w") as f:
    json.dump({
        "timestamp": ts,
        "expectedWords": expected,
        "transcribedWords": got,
        "matchPercent": round(got / expected * 100, 1) if expected else 0,
        "transcriptPreview": transcript[:800]
    }, f, indent=2)
print(f"Saved: {path}")
PY

if [ "$RESULT_WORDS" -gt 0 ]; then
  echo ""
  echo "Preview:"
  head -c 400 "$OUTPUT_FILE"
  echo "..."
fi
