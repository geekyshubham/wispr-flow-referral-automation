#!/usr/bin/env bash
# Close leftover ego-browser task spaces created by this automation.
# Does not quit ego lite or the user's other tabs.
set -u
if ! command -v ego-browser >/dev/null 2>&1; then
  echo "  ego-browser not on PATH; skipped task-space close."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HEADER=$(python3 - "$SCRIPT_DIR" <<'PY'
from pathlib import Path
import json, sys
root = Path(sys.argv[1])
print('const pendingPath = ' + json.dumps(str(root / 'data/pending-signup.json')) + ';')
print('const moduleUrl = ' + json.dumps((root / 'lib/web-auth.mjs').as_uri()) + ';')
PY
)
ego-browser nodejs <<EOF 2>/dev/null || true
${HEADER}
const { readJson, writeJson } = await import(moduleUrl)
const pending = await readJson(pendingPath)
if (!pending?.taskSpaceId || pending.taskSpaceClosed) process.exit(0)
const spaces = await listTaskSpaces()
let closed = 0
for (const s of spaces || []) {
  const name = String(s.name || s.taskId || '')
  if (s.id !== pending.taskSpaceId) continue
  try {
    if (s.ownership === 'user' || s.ownership === 'agentDelegatedToUser') {
      console.log('KEEP_SPACE:' + name + ':awaiting user');
      continue
    }
    const task = await taskSpace(s.id)
    await task.finish({ keep: [] })
    await writeJson(pendingPath, { ...pending, taskSpaceClosed: true })
    closed += 1
    console.log('CLOSED_SPACE:' + name)
  } catch (e) {
    console.log('SKIP_SPACE:' + name + ':' + String(e && e.message || e))
  }
}
console.log('CLOSED_COUNT:' + closed)
EOF
