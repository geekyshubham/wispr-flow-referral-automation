#!/usr/bin/env bash
# Stop the user's main Wispr Flow without touching the isolated test instance.
ISOLATED_PROFILE="${1:-}"
ISOLATED_PROFILE="$(cd "$ISOLATED_PROFILE" 2>/dev/null && pwd || echo "$ISOLATED_PROFILE")"

for pid in $(pgrep -f "Wispr Flow" 2>/dev/null || true); do
  args=$(ps -p "$pid" -o args= 2>/dev/null || true)
  [ -z "$args" ] && continue
  case "$args" in
    *user-data-dir="${ISOLATED_PROFILE}"*) continue ;;
    *swift-helper-app-dist*) continue ;;
    *"Wispr Flow Helper"*) continue ;;
  esac
  case "$args" in
    */Contents/MacOS/Wispr\ Flow*)
      case "$args" in
        *user-data-dir=*) ;;
        *) kill "$pid" 2>/dev/null || true ;;
      esac
      ;;
  esac
done
sleep 1
