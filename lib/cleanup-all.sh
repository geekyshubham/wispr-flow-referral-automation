#!/usr/bin/env bash
# Full reset after the automation: extra isolated Wispr gone, ego task spaces
# closed, Built-in mic/speakers restored, main Wispr left running / relaunched.
# Never touches the user's real Wispr profile
# (~/Library/Application Support/Wispr Flow).
# Usage: cleanup-all.sh [--stop-job]
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILES="${SCRIPT_DIR}/profiles"
PID_FILE="${SCRIPT_DIR}/data/wispr-run.pid"

echo "Resetting Mac after Wispr referral automation..."

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

# Only kill Wispr instances whose --user-data-dir is under this repo's profiles/.
# Paths contain spaces ("Application Support") so never split on the first space.
python3 "${SCRIPT_DIR}/lib/kill-isolated-wispr.py" "$PROFILES" || true

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
echo "  Cleanup complete — extra instances and residues removed."
