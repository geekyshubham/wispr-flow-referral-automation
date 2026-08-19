#!/usr/bin/env bash
# Diagnose local vs server word stats for an isolated Wispr profile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${1:-${SCRIPT_DIR}/profiles/flowtest64407}"

python3 - "$PROFILE" <<'PY'
import json, sys, os
from datetime import datetime, timezone

profile = sys.argv[1]
config_path = os.path.join(profile, "config.json")
session_path = os.path.join(profile, "session.json")

print("=== Wispr Flow Status ===")
print(f"Profile: {profile}")

try:
    with open(config_path) as f:
        cfg = json.load(f)
    stats = cfg.get("prefs", {}).get("cache", {}).get("statistics", {})
    user = cfg.get("prefs", {}).get("user", {})
    print(f"Email: {user.get('email', '?')}")
    print(f"Local totalWords: {stats.get('totalWords', 0)}")
    print(f"Local wordsToday: {stats.get('wordsToday', 0)}")
    print(f"Last transcript: {stats.get('lastTranscriptTimestamp', 'never')}")
except FileNotFoundError:
    print("No config.json — profile not initialized")

try:
    with open(session_path) as f:
        sess = json.load(f)
    token = json.loads(sess["sb-dodjkfqhwrzqjwkfnthl-auth-token"])
    exp = token.get("expires_at")
    if exp:
        exp_dt = datetime.fromtimestamp(exp, tz=timezone.utc)
        print(f"Auth expires: {exp_dt.isoformat()}")
    print(f"Logged in as: {token.get('user', {}).get('email', '?')}")
except (FileNotFoundError, KeyError, json.JSONDecodeError):
    print("Session: NOT logged in (session.json missing or invalid)")

log = os.path.join(os.path.dirname(profile).replace("/profiles", ""), "data", "isolated-wispr.log")
if os.path.isfile(log):
    with open(log) as f:
        lines = f.readlines()
    for line in reversed(lines):
        if "User stats not initialized on the remote server" in line:
            print("\nServer sync: stats NOT on Wispr servers yet (referral dashboard will show 0)")
            break
    else:
        print("\nServer sync: check isolated-wispr.log manually")

print("\nAutomated dictation:")
print("  bash lib/dictate-handsfree.sh profiles/flowtest64407 2000")
print("  Uses wispr-flow://start-hands-free deeplink + BlackHole audio loopback")
PY
