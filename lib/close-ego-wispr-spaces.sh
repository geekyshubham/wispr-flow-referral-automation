#!/usr/bin/env bash
# Close leftover ego-browser task spaces created by this automation.
# Does not quit ego lite or the user's other tabs.
set -u
if ! command -v ego-browser >/dev/null 2>&1; then
  echo "  ego-browser not on PATH; skipped task-space close."
  exit 0
fi

ego-browser nodejs <<'EOF' 2>/dev/null || true
const spaces = await listTaskSpaces()
let closed = 0
for (const s of spaces || []) {
  const name = String(s.name || s.taskId || '')
  if (!/^wispr/i.test(name)) continue
  try {
    await completeTaskSpace(s.id, { keep: false })
    closed += 1
    cliLog('CLOSED_SPACE:' + name)
  } catch (e) {
    cliLog('SKIP_SPACE:' + name + ':' + String(e && e.message || e))
  }
}
cliLog('CLOSED_COUNT:' + closed)
EOF
