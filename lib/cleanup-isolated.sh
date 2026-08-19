#!/usr/bin/env bash
# Stop and delete isolated Wispr Flow profile (does NOT touch main Wispr account)
set -euo pipefail

PROFILE_DIR="${1:-}"
if [ -z "$PROFILE_DIR" ]; then
  echo "Usage: $0 <profile-dir>"
  exit 1
fi

echo "Cleaning up isolated Wispr instance..."
pkill -f "user-data-dir=${PROFILE_DIR}" 2>/dev/null || true
sleep 3
pkill -9 -f "user-data-dir=${PROFILE_DIR}" 2>/dev/null || true

if [ -d "$PROFILE_DIR" ]; then
  rm -rf "$PROFILE_DIR"
  echo "  Deleted profile: $PROFILE_DIR"
else
  echo "  Profile already removed"
fi

echo "  Main Wispr Flow account untouched."
