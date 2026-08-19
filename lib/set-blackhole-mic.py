#!/usr/bin/env python3
"""Point Wispr profile at BlackHole virtual mic for loopback dictation."""
import json
import sys

BLACKHOLE_ID = "9bf7ea08d316e4b7032b86e31def6911a6f22fbc45f8309f9341716891e73eeb"
path = sys.argv[1]

with open(path) as f:
    cfg = json.load(f)

user = cfg.setdefault("prefs", {}).setdefault("user", {})
user["overrideAudioDeviceId"] = BLACKHOLE_ID

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)

print(f"Set overrideAudioDeviceId to BlackHole in {path}")
