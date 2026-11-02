#!/usr/bin/env python3
"""Print how many accounts are stored. Returns 0 if the file is missing or invalid."""
import json
import sys

path = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    with open(path) as f:
        print(len(json.load(f)))
except Exception:
    print(0)
