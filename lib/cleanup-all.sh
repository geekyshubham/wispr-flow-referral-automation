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

TOKEN_FILE="${SCRIPT_DIR}/data/wispr-run-token"
# A stale job must return before killing processes or touching any files.
if [ "${1:-}" != "--stop-job" ] && [ -n "${WISPR_RUN_TOKEN:-}" ] && \
   [ "$(cat "$TOKEN_FILE" 2>/dev/null || true)" != "$WISPR_RUN_TOKEN" ]; then
  echo "Skipping stale cleanup (a newer run is active)."
  exit 0
fi

if [ "${1:-}" = "--stop-job" ]; then
  mkdir -p "${SCRIPT_DIR}/data"
  # Invalidate EXIT traps from jobs we are about to kill so they cannot
  # close ego-browser spaces / profiles of a later run.
  echo "stopped-$(date +%s)" > "$TOKEN_FILE"
  python3 "${SCRIPT_DIR}/lib/job-lock.py" --stop --name next-inbox "$SCRIPT_DIR" || exit $?
  python3 "${SCRIPT_DIR}/lib/job-lock.py" --stop "$SCRIPT_DIR" || exit $?
  # Reacquire before reset: a newer job winning this race must be left alone.
  unset WISPR_RUN_TOKEN
  exec python3 "${SCRIPT_DIR}/lib/job-lock.py" "$SCRIPT_DIR" bash "$0" --reset-after-stop
fi
if ! python3 "${SCRIPT_DIR}/lib/job-lock.py" --is-held "$SCRIPT_DIR"; then
  exec python3 "${SCRIPT_DIR}/lib/job-lock.py" "$SCRIPT_DIR" bash "$0" "${1:-}"
fi
echo "Resetting Mac after Wispr referral automation..."

# Only kill Wispr instances whose --user-data-dir is under this repo's profiles/.
# Paths contain spaces ("Application Support") so never split on the first space.
python3 "${SCRIPT_DIR}/lib/kill-isolated-wispr.py" "$PROFILES" || true

echo "  Incomplete profiles kept for resume; completed profiles clean up individually."

rm -f /tmp/wispr-tts*.aiff /tmp/wispr-flow-config.json.bak /tmp/wispr_resp.json 2>/dev/null || true
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'wispr-tts*' -delete 2>/dev/null || true

if [ "${PRESERVE_WISPR_TASK_SPACES:-0}" = "1" ]; then
  echo "  Signup page preserved for diagnosis/resume."
else
  bash "${SCRIPT_DIR}/lib/close-ego-wispr-spaces.sh" 2>/dev/null || true
  echo "  Agent-owned Wispr task spaces closed (human handoffs kept open)."
fi

bash "${SCRIPT_DIR}/lib/restore-audio.sh" restore 2>/dev/null || true
bash "${SCRIPT_DIR}/lib/restore-audio.sh" builtin 2>/dev/null || true
echo "  Mic and speakers: Built-in."

bash "${SCRIPT_DIR}/lib/resume-main-wispr.sh" 2>/dev/null || true
echo "  Cleanup complete — extra instances and residues removed."
