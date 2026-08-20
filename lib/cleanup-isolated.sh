#!/usr/bin/env bash
# Stop isolated Wispr, restore system mic/speakers, delete the temp profile.
# Usage: cleanup-isolated.sh <profile-dir>
# Never kills the real app at ~/Library/Application Support/Wispr Flow.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE_DIR="${1:-}"
if [ -z "$PROFILE_DIR" ]; then
  echo "Usage: $0 <profile-dir>"
  exit 1
fi
PROFILE_DIR="$(cd "$PROFILE_DIR" 2>/dev/null && pwd || echo "$PROFILE_DIR")"
PROFILES_ROOT="${SCRIPT_DIR}/profiles"
MAIN_PROFILE="${HOME}/Library/Application Support/Wispr Flow"

case "$PROFILE_DIR" in
  "${MAIN_PROFILE}"|"${MAIN_PROFILE}"/*)
    echo "refusing to clean the real Wispr Flow profile: ${PROFILE_DIR}"
    exit 1
    ;;
esac
case "$PROFILE_DIR" in
  "${PROFILES_ROOT}"|"${PROFILES_ROOT}"/*) ;;
  *)
    echo "refusing to clean a path outside ${PROFILES_ROOT}: ${PROFILE_DIR}"
    exit 1
    ;;
esac

echo "Cleaning up isolated Wispr instance..."
python3 "${SCRIPT_DIR}/lib/kill-isolated-wispr.py" "$PROFILE_DIR"

if [ "${KEEP_PROFILE:-}" = "1" ]; then
  echo "  KEEP_PROFILE=1 — left ${PROFILE_DIR} on disk (history not confirmed on server)"
elif [ -d "$PROFILE_DIR" ]; then
  rm -rf "$PROFILE_DIR"
  echo "  Deleted profile: ${PROFILE_DIR}"
fi

bash "${SCRIPT_DIR}/lib/restore-audio.sh" restore 2>/dev/null || true
bash "${SCRIPT_DIR}/lib/restore-audio.sh" builtin 2>/dev/null || true
echo "  System mic and speakers restored."
echo "  Main Wispr Flow account data untouched."
