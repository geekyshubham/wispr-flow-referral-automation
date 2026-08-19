#!/usr/bin/env bash
# Stop isolated Wispr, restore system mic/speakers, optionally delete the profile.
# Usage: cleanup-isolated.sh <profile-dir>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_DIR="${1:-}"
if [ -z "$PROFILE_DIR" ]; then
  echo "Usage: $0 <profile-dir>"
  exit 1
fi

echo "Cleaning up isolated Wispr instance..."
pkill -f "user-data-dir=${PROFILE_DIR}" 2>/dev/null || true
sleep 2
pkill -9 -f "user-data-dir=${PROFILE_DIR}" 2>/dev/null || true

if [ -d "$PROFILE_DIR" ]; then
  rm -rf "$PROFILE_DIR"
  echo "  Deleted profile: ${PROFILE_DIR}"
fi

bash "${SCRIPT_DIR}/lib/restore-audio.sh" restore 2>/dev/null || true
bash "${SCRIPT_DIR}/lib/restore-audio.sh" builtin 2>/dev/null || true
echo "  System mic and speakers restored."
echo "  Main Wispr Flow account data untouched."
