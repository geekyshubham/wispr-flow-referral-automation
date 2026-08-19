#!/usr/bin/env bash
# Save or restore macOS default input/output so BlackHole tests don't stick.
# Usage: restore-audio.sh save|restore
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${SCRIPT_DIR}/lib/audio-defaults.bin"
SRC="${SCRIPT_DIR}/lib/audio-defaults.swift"
STATE="${SCRIPT_DIR}/data/audio-defaults.json"
mkdir -p "$(dirname "$STATE")"

if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
  xcrun swiftc -O "$SRC" -o "$BIN"
fi

cmd="${1:-builtin}"
case "$cmd" in
  builtin)
    "$BIN" builtin
    ;;
  save|restore)
    "$BIN" "$cmd" "$STATE"
    ;;
  *)
    echo "Usage: $0 save|restore|builtin"
    exit 1
    ;;
esac
