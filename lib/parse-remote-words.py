#!/usr/bin/env python3
"""Parse isolated Wispr logs for remote/server word stats and upload progress."""
from __future__ import annotations

import json
import re
import sys

REMOTE_RE = re.compile(
    r"Remote stats are invalid.*?Remote stats:\s*\{(.*?)\n\}",
    re.S,
)
UPLOADED_RE = re.compile(r"Uploaded (\d+) transcripts with IDs:")
PENDING_RE = re.compile(r"Uploading history, (\d+) transcripts with needsUploading: true")
FAIL_503_RE = re.compile(r"Too many concurrent requests")
SKIP_BATCH_RE = re.compile(r"would not exceed the size limit, skipping upload to batch")


def parse(log_text: str) -> dict:
    remote_words = None
    for m in REMOTE_RE.finditer(log_text):
        block = m.group(1)
        tw = re.search(r"totalWords:\s*(\d+)", block)
        if tw:
            remote_words = int(tw.group(1))
    uploaded = sum(int(n) for n in UPLOADED_RE.findall(log_text))
    pending = None
    for n in PENDING_RE.findall(log_text):
        pending = int(n)
    return {
        "remote_total_words": remote_words,
        "uploaded_transcripts": uploaded,
        "last_needs_uploading": pending,
        "saw_503": bool(FAIL_503_RE.search(log_text)),
        "saw_skip_small_batch": bool(SKIP_BATCH_RE.search(log_text)),
    }


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        text = open(path, errors="replace").read()
    except FileNotFoundError:
        text = ""
    print(json.dumps(parse(text)))
