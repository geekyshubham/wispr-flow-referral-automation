#!/usr/bin/env python3
"""Turn on usage sharing + cloud sync so isolated Wispr will upload history metadata."""
import json
import sys

path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)

user = cfg.setdefault("prefs", {}).setdefault("user", {})
user["shareUsageData"] = True
user["cloudSync"] = True
user["onboardingCompleted"] = True
user["postOnboardingCompleted"] = True
user["speedyOnboardingAccepted"] = True
user["initialSubscriptionSynced"] = True
if "pagesCompleted" not in user:
    user["pagesCompleted"] = [{"page": "welcome-basic", "completed": True}]

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)

print("Enabled shareUsageData + cloudSync + onboardingCompleted")
