#!/usr/bin/env python3
"""Reject profiles/active file handles that reach personal Wispr storage."""
import json
import hashlib
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def profile_key(email):
    email = email.strip().lower()
    if email.count('@') != 1 or any(c.isspace() for c in email) or not all(email.split('@')):
        raise ValueError('Invalid account email')
    slug = re.sub(r'[^a-z0-9_-]', '-', email.split('@')[0])[:30]
    return slug + '-' + hashlib.sha256(email.encode()).hexdigest()[:12]


def check_profile(raw):
    profile = Path(raw).resolve()
    if not profile.is_relative_to((ROOT / 'profiles').resolve()) or profile == (ROOT / 'profiles').resolve():
        raise RuntimeError('Profile must be inside this repository profiles/ directory')
    for name in ('config.json', 'session.json', 'flow.sqlite', 'flow.sqlite-wal', 'flow.sqlite-shm', 'logs'):
        path = profile / name
        if path.is_symlink() or not path.resolve().is_relative_to(profile):
            raise RuntimeError('Refusing linked profile data: ' + str(path))
    return profile


def audit(raw, pid):
    profile = check_profile(raw)
    if not (profile / 'flow.sqlite').is_file():
        raise RuntimeError('Isolated app did not create its own history database')
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid='], text=True).splitlines()
    parents = {int(p): int(pp) for p, pp in (row.split() for row in rows)}
    selected = {int(pid)}
    while True:
        more = {p for p, parent in parents.items() if parent in selected}
        if more.issubset(selected):
            break
        selected.update(more)
    result = subprocess.run(['lsof', '-a', '-p', ','.join(map(str, selected)), '-Fn'], text=True, capture_output=True)
    paths = [Path(line[1:]) for line in result.stdout.splitlines() if line.startswith('n/')]
    forbidden = [Path.home() / 'Library/Application Support/Wispr Flow',
                 Path.home() / 'Library/Application Support/Flow', Path.home() / 'Library/Logs/Wispr Flow']
    bad = [str(path) for path in paths if any(path.is_relative_to(root) for root in forbidden)]
    if bad:
        raise RuntimeError('Test app opened personal Wispr storage: ' + ', '.join(sorted(set(bad))))
    database = profile / 'flow.sqlite'
    if database not in paths:
        raise RuntimeError('Cannot prove the isolated app owns its history database')
    (ROOT / 'data/runtime-audit.json').write_text(json.dumps({'profile': str(profile), 'pid': int(pid), 'historyDatabase': str(database), 'personalHandles': bad}, indent=2) + '\n')
    print('  Isolation verified: own history DB; no personal Wispr data/log handles.')


if __name__ == '__main__':
    try:
        if len(sys.argv) > 2 and sys.argv[1] == '--key':
            print(profile_key(sys.argv[2]))
        elif len(sys.argv) > 2:
            audit(sys.argv[1], sys.argv[2])
        else:
            check_profile(sys.argv[1])
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print('ERROR:' + str(error), file=sys.stderr)
        sys.exit(1)
