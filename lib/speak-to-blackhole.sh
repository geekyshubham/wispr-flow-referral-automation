#!/usr/bin/env bash
# Speak text into BlackHole loopback so Wispr mic captures it reliably.
# Usage: speak-to-blackhole.sh "<text>" [rate]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEXT="${1:?text required}"
RATE="${2:-170}"
TMP=$(mktemp -t wispr-tts).aiff

say -r "$RATE" -o "$TMP" "$TEXT"
swift "${SCRIPT_DIR}/play-to-device.swift" "BlackHole 2ch" "$TMP"
rm -f "$TMP"
