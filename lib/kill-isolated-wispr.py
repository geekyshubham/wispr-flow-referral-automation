#!/usr/bin/env python3
"""Kill only isolated Wispr processes (user-data-dir under this repo's profiles/)."""
import os
import signal
import subprocess
import sys
import time

PROFILES = os.path.realpath(sys.argv[1] if len(sys.argv) > 1 else "")
if not PROFILES:
    sys.exit("usage: kill-isolated-wispr.py <profiles-dir>")


def user_data_dir(cmd: str):
    marker = "--user-data-dir="
    idx = cmd.find(marker)
    if idx < 0:
        return None
    rest = cmd[idx + len(marker) :]
    if rest.startswith('"'):
        end = rest.find('"', 1)
        return rest[1:end] if end > 0 else rest[1:]
    # Path may contain spaces; Chromium's next flag is " --foo"
    cut = rest.find(" --")
    return rest[:cut] if cut >= 0 else rest.strip()


def isolated(cmd: str) -> bool:
    if "Wispr Flow" not in cmd:
        return False
    path = user_data_dir(cmd)
    if not path:
        return False
    path = os.path.realpath(path)
    return path == PROFILES or path.startswith(PROFILES + os.sep)


def pids():
    out = subprocess.check_output(["ps", "-ax", "-o", "pid=", "-o", "command="], text=True)
    found = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        pid_s, _, cmd = line.partition(" ")
        if isolated(cmd):
            try:
                found.append(int(pid_s))
            except ValueError:
                pass
    return found


def kill_all(sig):
    n = 0
    for pid in pids():
        try:
            os.kill(pid, sig)
            n += 1
        except OSError:
            pass
    return n


term = kill_all(signal.SIGTERM)
if term:
    time.sleep(2)
    kill_all(signal.SIGKILL)
print(f"  Stopped {term} isolated Wispr process(es).")
