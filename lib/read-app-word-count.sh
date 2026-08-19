#!/usr/bin/env bash
# Try to read total word count from Wispr Flow app UI (Accessibility)
# Falls back to empty if not readable
PROFILE_DIR="${1:-}"
WISPR_CONFIG="${PROFILE_DIR}/config.json"

# Prefer config.json (same data shown on main page, updates after sync)
if [ -n "$PROFILE_DIR" ] && [ -f "$WISPR_CONFIG" ]; then
  python3 "${PROFILE_DIR%/profiles/*}/lib/word-count.py" "$PROFILE_DIR" 2>/dev/null && exit 0
fi

# Try Accessibility on Wispr Flow window text
osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
  if not (exists process "Wispr Flow") then return ""
  tell process "Wispr Flow"
    set uiText to ""
    try
      repeat with w in windows
        set uiText to uiText & (value of static texts of w as text) & " "
      end repeat
    end try
    return uiText
  end tell
end tell
APPLESCRIPT
