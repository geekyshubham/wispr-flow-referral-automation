#!/usr/bin/env bash
# Full reset after the automation: extra Wispr instances gone, ego task spaces
# closed, Built-in mic/speakers restored, main Wispr relaunched.
# Does not touch the user's Wispr account data or quit ego lite.
# Usage: cleanup-all.sh [--stop-job]
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILES="${SCRIPT_DIR}/profiles"
PID_FILE="${SCRIPT_DIR}/data/wispr-run.pid"
MAIN_DATA="${HOME}/Library/Application Support/Wispr Flow"

echo "Resetting Mac after Wispr referral automation..."

open -g "wispr-flow://stop-hands-free" >/dev/null 2>&1 || true
sleep 1

if [ "${1:-}" = "--stop-job" ]; then
  if [ -f "$PID_FILE" ]; then
    job_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "${job_pid:-}" ]; then
      kill "$job_pid" 2>/dev/null || true
      sleep 1
      kill -9 "$job_pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
  pkill -f "${SCRIPT_DIR}/wispr-complete-flow" 2>/dev/null || true
  pkill -f "${SCRIPT_DIR}/lib/dictate-fast.sh" 2>/dev/null || true
  pkill -f "${SCRIPT_DIR}/lib/dictate-handsfree.sh" 2>/dev/null || true
  pkill -f "${SCRIPT_DIR}/wispr-test" 2>/dev/null || true
  pkill -f "${SCRIPT_DIR}/lib/play-to-device.bin" 2>/dev/null || true
fi

# Extra Wispr instances = any Wispr/Helper whose user-data-dir is not the real app data.
python3 - "$MAIN_DATA" "$PROFILES" <<'PY' || true
import os, sys, signal, subprocess
main = os.path.realpath(sys.argv[1])
profiles = os.path.realpath(sys.argv[2]) if len(sys.argv) > 2 else ""
out = subprocess.check_output(["ps", "-ax", "-o", "pid=", "-o", "command="], text=True)
killed = 0
for line in out.splitlines():
    line = line.strip()
    if not line:
        continue
    pid_s, _, cmd = line.partition(" ")
    if "Wispr Flow" not in cmd:
        continue
    if "user-data-dir=" not in cmd:
        continue
    marker = cmd.split("user-data-dir=", 1)[1]
    path = marker.split(" ", 1)[0]
    path = os.path.realpath(path)
    if path == main or path.startswith(main + os.sep):
        continue
    try:
        os.kill(int(pid_s), signal.SIGTERM)
        killed += 1
    except OSError:
        pass
print(f"  Stopped {killed} extra Wispr process(es).")
PY
sleep 2
python3 - "$MAIN_DATA" <<'PY' || true
import os, sys, signal, subprocess
main = os.path.realpath(sys.argv[1])
out = subprocess.check_output(["ps", "-ax", "-o", "pid=", "-o", "command="], text=True)
for line in out.splitlines():
    line = line.strip()
    if not line or "Wispr Flow" not in line or "user-data-dir=" not in line:
        continue
    pid_s, _, cmd = line.partition(" ")
    path = os.path.realpath(cmd.split("user-data-dir=", 1)[1].split(" ", 1)[0])
    if path == main or path.startswith(main + os.sep):
        continue
    try:
        os.kill(int(pid_s), signal.SIGKILL)
    except OSError:
        pass
PY

pkill -f "user-data-dir=${PROFILES}" 2>/dev/null || true
pkill -9 -f "user-data-dir=${PROFILES}" 2>/dev/null || true

if [ -d "$PROFILES" ]; then
  rm -rf "${PROFILES:?}/"*
  echo "  Isolated profiles removed."
fi

rm -f /tmp/wispr-tts*.aiff /tmp/wispr-flow-config.json.bak /tmp/wispr_resp.json 2>/dev/null || true
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'wispr-tts*' -delete 2>/dev/null || true

bash "${SCRIPT_DIR}/lib/close-ego-wispr-spaces.sh" 2>/dev/null || true
echo "  ego-browser Wispr task spaces closed (ego lite itself left running)."

bash "${SCRIPT_DIR}/lib/restore-audio.sh" restore 2>/dev/null || true
bash "${SCRIPT_DIR}/lib/restore-audio.sh" builtin 2>/dev/null || true
echo "  Mic and speakers: Built-in."

bash "${SCRIPT_DIR}/lib/resume-main-wispr.sh" 2>/dev/null || true
echo "  Main Wispr Flow relaunched."
echo "  Cleanup complete — extra instances and residues removed."
