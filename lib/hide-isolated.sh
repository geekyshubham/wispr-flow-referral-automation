#!/usr/bin/env bash
# Hide isolated Wispr Flow windows without activating or stealing focus.
ABS_PROFILE="${1:?profile dir}"
PID=$(pgrep -f "user-data-dir=${ABS_PROFILE}" | head -1)
[ -n "$PID" ] || exit 0
osascript -e "tell application \"System Events\" to set visible of (every process whose unix id is ${PID}) to false" >/dev/null 2>&1 || true
