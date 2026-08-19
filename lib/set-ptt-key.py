#!/usr/bin/env python3
"""Set Wispr Flow profile PTT shortcut to a simulatable key (default: Right Option = 61)."""
import json
import sys

KEY = int(sys.argv[2]) if len(sys.argv) > 2 else 61
path = sys.argv[1]

with open(path) as f:
    cfg = json.load(f)

user = cfg.setdefault("prefs", {}).setdefault("user", {})
shortcuts = user.setdefault("shortcuts", {})
shortcuts[str(KEY)] = "ptt"
for old in ("63", "4098"):
    shortcuts.pop(old, None)

cache = cfg.setdefault("prefs", {}).setdefault("cache", {})
for item in cache.get("splitKeybinds", []):
    if item.get("value") == "ptt":
        item["shortcut"] = [KEY]

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)

print(f"PTT set to keycode {KEY} in {path}")
