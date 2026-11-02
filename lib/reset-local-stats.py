#!/usr/bin/env python3
"""Zero isolated-profile local word cache so a cloned main-app config cannot skip dictation."""
import json
import os
import sys

raw = sys.argv[1]
path = raw if raw.endswith("config.json") else os.path.join(raw.rstrip("/"), "config.json")
if not os.path.isfile(path):
    print("  No config.json to reset")
    sys.exit(0)

with open(path) as f:
    cfg = json.load(f)

prefs = cfg.setdefault("prefs", {})
cache = prefs.setdefault("cache", {})
stats = cache.setdefault("statistics", {})
before = int(stats.get("totalWords") or 0)
stats["totalWords"] = 0
stats["wordsToday"] = 0
stats["wordsThisWeek"] = 0
email = prefs.get("user", {}).get("email", "")

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)

print(f"  Reset local cache totalWords {before} -> 0 (email={email or '?'})")
