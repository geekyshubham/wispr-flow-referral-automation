#!/usr/bin/env python3
"""Read totalWords from Wispr Flow profile config.json."""
import json
import sys

def get_total_words(profile_dir: str) -> int:
    path = f"{profile_dir.rstrip('/')}/config.json"
    try:
        with open(path) as f:
            data = json.load(f)
        return int(data.get("prefs", {}).get("cache", {}).get("statistics", {}).get("totalWords", 0))
    except (FileNotFoundError, json.JSONDecodeError, KeyError, TypeError, ValueError):
        return 0

if __name__ == "__main__":
    print(get_total_words(sys.argv[1] if len(sys.argv) > 1 else ""))
