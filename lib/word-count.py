#!/usr/bin/env python3
"""Count real transcripts in a verified repository-local history database."""
from pathlib import Path
import sqlite3
import sys

def get_total_words(profile_dir: str, pending=False) -> int:
    root = Path(__file__).resolve().parents[1] / 'profiles'
    profile = Path(profile_dir).resolve()
    if profile == root.resolve() or not profile.is_relative_to(root.resolve()):
        raise ValueError('Word counts are restricted to repository-local test profiles')
    path = profile / 'flow.sqlite'
    if path.is_symlink():
        raise ValueError('Refusing a linked history database')
    if not path.exists():
        return 0
    with sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=5) as db:
        return max(0, int(db.execute('SELECT COALESCE(SUM(numWords), 0) FROM History' + (' WHERE needsUploading = 1' if pending else '')).fetchone()[0]))

if __name__ == "__main__":
    args = [arg for arg in sys.argv[1:] if arg != "--pending"]
    print(get_total_words(args[0] if args else "", pending="--pending" in sys.argv))
