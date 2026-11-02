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
    if sess.get("authProviderId") == "workos":
        workos = sess["workosSession"]
        token = {"expires_at": workos.get("expiresAt"), "user": {"email": workos.get("email")}}
        print("Auth provider: WorkOS")
    else:
        token = json.loads(sess["sb-dodjkfqhwrzqjwkfnthl-auth-token"])
    exp = token.get("expires_at")
    if exp:
        exp_dt = datetime.fromtimestamp(exp, tz=timezone.utc)
        print(f"Auth expires: {exp_dt.isoformat()}")
    print(f"Logged in as: {token.get('user', {}).get('email', '?')}")
except (FileNotFoundError, KeyError, json.JSONDecodeError):
    print("Session: NOT logged in (session.json missing or invalid)")

repo = os.path.dirname(os.path.dirname(os.path.abspath(profile)))
stats_py = os.path.join(repo, "lib", "fetch-server-stats.py")
if os.path.isfile(session_path) and os.path.isfile(stats_py):
    import subprocess
    try:
        out = subprocess.check_output(["python3", stats_py, profile], text=True, timeout=30)
        print("\nServer /history/stats:")
        print(out[:1500])
    except Exception as e:
        print(f"\nServer /history/stats: failed ({e})")

log = os.path.join(repo, "data", "isolated-wispr.log")
if os.path.isfile(log):
    with open(log) as f:
        text = f.read()
    if "Too many concurrent requests" in text:
        print("History upload: saw HTTP 503 (Too many concurrent requests)")
    if "skipping upload to batch" in text:
        print("History upload: small batches were skipped (need idle time / force sync)")
    if "Uploaded " in text:
        print("History upload: at least one transcript reached the server")
    if "User stats not initialized on the remote server" in text:
        print("Server sync: stats NOT initialized remotely yet")

print("\nAutomated dictation:")
print("  ./wispr-complete-flow   # waits for SERVER /history/stats, not local cache")
print("  Referral credit uses server total_words. Local cache can lie.")
PY
