#!/usr/bin/env python3
"""Start wispr-run in a new session so agent/shell teardown cannot SIGKILL it."""
import os
from pathlib import Path
import sys

script, log_path, pid_path, accounts, words, referral = sys.argv[1:7]
root = str(Path(script).resolve().parent)
os.execv(sys.executable, [sys.executable, str(Path(root, 'lib/job-lock.py')), '--detach', root,
                        script, '--accounts', accounts, '--words', words,
                        '--referral', referral, '--foreground'])
