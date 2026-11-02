#!/usr/bin/env python3
"""Hold a kernel file lock until the parent's stdin pipe closes."""
import fcntl
from pathlib import Path
import sys
import time

path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
with path.open('a') as lock:
    deadline = time.monotonic() + 180
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise SystemExit('Timed out waiting for ' + str(path))
            time.sleep(0.1)
    print('LOCKED', flush=True)
    sys.stdin.buffer.read()
