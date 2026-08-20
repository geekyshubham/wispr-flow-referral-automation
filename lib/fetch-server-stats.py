#!/usr/bin/env python3
"""Fetch Wispr /history/stats for a session. Referral credit uses SERVER words, not local cache.

Usage:
  python3 lib/fetch-server-stats.py <profile_dir>
  python3 lib/fetch-server-stats.py --token-json '<supabase session json>'
  python3 lib/fetch-server-stats.py --token-file session.json
"""
from __future__ import annotations

import json
import ssl
import sys
import urllib.error
import urllib.request

STATS_URL = "https://api.wisprflow.ai/history/stats"
CTX = ssl.create_default_context()


def access_token_from_session(session_obj: object) -> str | None:
    if isinstance(session_obj, str):
        session_obj = json.loads(session_obj)
    if not isinstance(session_obj, dict):
        return None
    raw = session_obj.get("sb-dodjkfqhwrzqjwkfnthl-auth-token", session_obj)
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except json.JSONDecodeError:
            return None
    if isinstance(raw, dict):
        return raw.get("access_token")
    return None


def load_token(argv: list[str]) -> str:
    if len(argv) >= 3 and argv[1] == "--token-json":
        tok = access_token_from_session(argv[2])
        if tok:
            return tok
        parsed = json.loads(argv[2])
        if isinstance(parsed, dict) and parsed.get("access_token"):
            return parsed["access_token"]
        raise SystemExit("no access_token in --token-json")
    if len(argv) >= 3 and argv[1] == "--token-file":
        with open(argv[2]) as f:
            data = json.load(f)
        tok = access_token_from_session(data)
        if not tok:
            raise SystemExit(f"no access_token in {argv[2]}")
        return tok
    profile = argv[1] if len(argv) > 1 else ""
    path = f"{profile.rstrip('/')}/session.json"
    with open(path) as f:
        data = json.load(f)
    tok = access_token_from_session(data)
    if not tok:
        raise SystemExit(f"no access_token in {path}")
    return tok


def get_stats(token: str) -> tuple[int, dict]:
    last_err = None
    for auth in (token, f"Bearer {token}"):
        req = urllib.request.Request(
            STATS_URL,
            headers={
                "Authorization": auth,
                "Content-Type": "application/json",
                "Accept": "application/json",
                "Cache-Control": "no-cache",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=30, context=CTX) as resp:
                body = json.loads(resp.read().decode())
                return resp.status, body if isinstance(body, dict) else {"raw": body}
        except urllib.error.HTTPError as e:
            raw = e.read().decode(errors="replace")
            last_err = {"status": e.code, "body": raw[:500]}
            if e.code not in (401, 403):
                break
        except Exception as e:
            last_err = {"error": str(e)}
            break
    raise SystemExit("history/stats failed: " + json.dumps(last_err))


def total_words(payload: dict) -> int:
    for key in ("total_words", "totalWords"):
        if key in payload and payload[key] is not None:
            try:
                return int(payload[key])
            except (TypeError, ValueError):
                pass
    data = payload.get("data")
    if isinstance(data, dict):
        return total_words(data)
    return 0


if __name__ == "__main__":
    quiet = "--quiet" in sys.argv
    argv = [a for a in sys.argv if a != "--quiet"]
    token = load_token(argv)
    status, payload = get_stats(token)
    words = total_words(payload)
    out = {
        "http": status,
        "total_words": words,
        "is_initialized": payload.get("is_initialized", payload.get("data", {}).get("is_initialized") if isinstance(payload.get("data"), dict) else None),
        "words_this_week": payload.get("words_this_week", payload.get("wordsThisWeek")),
        "payload": payload,
    }
    if quiet:
        print(words)
    else:
        print(json.dumps(out, indent=2)[:4000])
