#!/usr/bin/env bash
# nohup/background jobs get a stripped PATH. Never depend on Homebrew or Cursor `rg`.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"
