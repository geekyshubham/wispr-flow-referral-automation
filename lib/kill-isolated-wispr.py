#!/usr/bin/env python3
"""Kill only isolated Wispr processes (user-data-dir under this repo's profiles/).

Never touches the real app at ~/Library/Application Support/Wispr Flow.
Paths contain spaces — never split --user-data-dir= on the first space.
"""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import time

MAIN_PROFILE_SUFFIX = os.path.join("Library", "Application Support", "Wispr Flow")


def user_data_dir(cmd: str) -> str | None:
    marker = "--user-data-dir="
    idx = cmd.find(marker)
    if idx < 0:
        return None
    rest = cmd[idx + len(marker) :]
    if rest.startswith('"'):
        end = rest.find('"', 1)
        return rest[1:end] if end > 0 else rest[1:]
    # Chromium's next flag is " --foo"; the path itself may contain spaces.
    cut = rest.find(" --")
    return rest[:cut] if cut >= 0 else rest.strip()


def is_main_profile(path: str) -> bool:
    norm = os.path.realpath(os.path.expanduser(path))
    main = os.path.realpath(os.path.expanduser(os.path.join("~", MAIN_PROFILE_SUFFIX)))
    return norm == main or norm.startswith(main + os.sep)


def is_isolated(cmd: str, profiles_root: str) -> bool:
    if "Wispr Flow" not in cmd:
        return False
    path = user_data_dir(cmd)
    if not path:
        return False
    if is_main_profile(path):
        return False
    root = os.path.realpath(profiles_root)
    path = os.path.realpath(path)
    return path == root or path.startswith(root + os.sep)


def isolated_pids(profiles_root: str, ps_text: str | None = None) -> list[int]:
    if ps_text is None:
        ps_text = subprocess.check_output(["ps", "-ax", "-o", "pid=", "-o", "command="], text=True)
    found: list[int] = []
    for line in ps_text.splitlines():
        line = line.strip()
        if not line:
            continue
        pid_s, _, cmd = line.partition(" ")
        if is_isolated(cmd, profiles_root):
            try:
                found.append(int(pid_s))
            except ValueError:
                pass
    return found


def self_test() -> None:
    home = os.path.expanduser("~")
    main = f"{home}/Library/Application Support/Wispr Flow"
    repo = "/tmp/wispr-flow-referral-automation/profiles"
    fake_iso = f"{repo}/flowtest1"
    main_cmd = (
        f"1234 /Applications/Wispr Flow.app/Contents/MacOS/Wispr Flow Helper "
        f"--type=gpu-process --user-data-dir={main} --gpu-preferences=SAAA"
    )
    iso_cmd = (
        f"5678 /Applications/Wispr Flow.app/Contents/MacOS/Wispr Flow "
        f"--user-data-dir={fake_iso} --some-flag=1"
    )
    quoted = (
        '9012 /Applications/Wispr Flow.app/Contents/MacOS/Wispr Flow '
        f'--user-data-dir="{fake_iso}" --flag'
    )
    no_dir = "111 /Applications/Wispr Flow.app/Contents/MacOS/Wispr Flow"

    assert user_data_dir(main_cmd) == main, user_data_dir(main_cmd)
    assert user_data_dir(iso_cmd) == fake_iso, user_data_dir(iso_cmd)
    assert user_data_dir(quoted) == fake_iso, user_data_dir(quoted)
    assert user_data_dir(no_dir) is None

    # The old bug: splitting on the first space yielded .../Library/Application
    buggy = user_data_dir(main_cmd).split(" ", 1)[0]
    assert buggy == f"{home}/Library/Application"
    assert buggy != main

    assert is_main_profile(main)
    assert is_main_profile(main + "/GPUCache")
    assert not is_isolated(main_cmd, repo)
    assert is_isolated(iso_cmd, repo)
    assert is_isolated(quoted, repo)
    assert not is_isolated(no_dir, repo)

    ps = f" 1234 {main_cmd[5:]}\n  5678 {iso_cmd[5:]}\n"
    assert isolated_pids(repo, ps) == [5678]
    print("kill-isolated-wispr self-test OK")


def kill_all(pids: list[int], sig: int) -> int:
    n = 0
    for pid in pids:
        try:
            os.kill(pid, sig)
            n += 1
        except OSError:
            pass
    return n


def main() -> None:
    if len(sys.argv) >= 2 and sys.argv[1] in ("--self-test", "-t"):
        self_test()
        return
    profiles = os.path.realpath(sys.argv[1] if len(sys.argv) > 1 else "")
    if not profiles:
        sys.exit("usage: kill-isolated-wispr.py <profiles-dir> | --self-test")
    if is_main_profile(profiles):
        sys.exit("refusing to target the real Wispr Flow profile")

    pids = isolated_pids(profiles)
    term = kill_all(pids, signal.SIGTERM)
    if term:
        time.sleep(2)
        leftover = isolated_pids(profiles)
        kill_all(leftover, signal.SIGKILL)
    print(f"  Stopped {term} isolated Wispr process(es).")


if __name__ == "__main__":
    main()
