#!/usr/bin/env python3
"""Restore corrupted totalWords from wordsToday when cache was reset by server sync."""
import json
import sys

path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)

stats = cfg.get("prefs", {}).get("cache", {}).get("statistics", {})
tw = stats.get("totalWords", 0)
today = stats.get("wordsToday", 0)

# If totalWords looks reset but wordsToday is high, restore from wordsToday
if tw < 500 and today > tw:
    stats["totalWords"] = today
    stats["wordsThisWeek"] = max(stats.get("wordsThisWeek", 0), today)
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    print(f"Restored totalWords: {tw} -> {today}")
else:
    print(f"No restore needed: totalWords={tw}, wordsToday={today}")
