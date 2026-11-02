#!/usr/bin/env bash
# Relaunch main Wispr Flow (default profile, no --user-data-dir) if it is not running.
set -u

main_running() {
  python3 - <<'PY'
import subprocess, sys
out = subprocess.check_output(["ps", "-ax", "-o", "command="], text=True)
for cmd in out.splitlines():
    if not cmd.startswith("/Applications/Wispr Flow.app/Contents/MacOS/Wispr Flow"):
        continue
    if "Helper" in cmd or "swift-helper-app-dist" in cmd:
        continue
    if "--user-data-dir=" in cmd:
        continue
    sys.exit(0)
sys.exit(1)
PY
}

if main_running; then
  echo "  Main Wispr Flow already running."
  exit 0
fi

open -a "/Applications/Wispr Flow.app"
for _ in 1 2 3 4 5; do
  sleep 1
  if main_running; then
    echo "  Main Wispr Flow relaunched."
    exit 0
  fi
done

# After a helper kill, Launch Services can no-op until the bundle is re-registered.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "/Applications/Wispr Flow.app" >/dev/null 2>&1 || true
fi
open "/Applications/Wispr Flow.app"
sleep 3
if main_running; then
  echo "  Main Wispr Flow relaunched."
  exit 0
fi
echo "  WARNING: could not relaunch main Wispr Flow. Open it from Applications."
exit 1
