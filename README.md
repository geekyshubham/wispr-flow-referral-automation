# Wispr Flow referral automation

Mac tool that creates **N** temp-mail Wispr accounts on your referral link, then simulates **W** dictated words on each account until all N are done. Isolated Wispr is used so your personal login is untouched. When the run finishes (or crashes), **system mic and speakers are restored** and your normal Wispr app is relaunched.

## Entire flow (per account, looped N times)

```
Maildrop inbox (mail.tm is optional)
  → signup at https://wisprflow.ai/r?SHUBHAM3680 (ego-browser, only Wispr auth state cleared)
  → email verification code (or legacy verification link)
  → isolated Wispr desktop login
  → BlackHole loopback dictation until W words
  → quit isolated instance, restore Built-in mic/speakers
repeat until N accounts have W words each
  → relaunch your normal Wispr Flow
```

Web-only signup stays **Pending / Under 2000 words**. Desktop dictation is required. Referral credit uses **server** `/history/stats` (`total_words`), not the local app cache. The job waits for history upload to succeed before treating an account as done.

## Customize N and W (runs in the background)

```bash
# 2 accounts, 2100 words each — returns immediately, job keeps going
./wispr-run --accounts 2 --words 2100

./wispr-run 2 2100                 # same
./wispr-run --accounts 1 --words 500
./wispr-run --fresh --accounts 1 --words 2100 --referral SHUBHAM3680
tail -f data/wispr-run.log         # watch progress
./wispr-run 2 2100 --foreground    # run in this terminal instead
./wispr-cleanup                    # abort + full reset anytime
```

Dictation uses a hidden isolated Wispr and plays TTS into BlackHole, not your speakers. An account is finished only after Wispr **servers** report `total_words` ≥ W (`GET /history/stats`). The desktop normally batches 10 transcripts. Once enough real words are queued, this tool restarts only the isolated test app to flush its history, then verifies the server count. Local progress comes from that profile’s history database, so stale cached statistics cannot finish an account. After **all** accounts finish (or you stop it), it resets: isolated instances quit, completed profiles deleted, incomplete profiles kept for resume, Built-in mic/speakers selected, your normal Wispr relaunched.

During the job your personal Wispr is paused so deeplinks hit the isolated instance; it comes back in the final cleanup. Signup may still pop ego-browser if hCaptcha needs a click (`./wispr-resume <task-space>`).

Live signup progress is written to `data/signup-progress.log` even while ego-browser buffers its terminal output. Maildrop is the default provider. It polls each inbox at most once every ten seconds and retrieves the full message separately, including MIME decoding. Set `MAIL_PROVIDER=mail.tm` to use mail.tm; its requests are spaced at least one second apart and paced by the server's `RateLimit-Policy`, saved between runs. HTTP 429 retries honor provider cooldowns, with at most three retries. A blocked signup stops the batch and saves its inbox and page in `data/pending-signup.json`. It does not repeatedly create new accounts. Resume that signup with `./wispr-resume`; it completes email verification, dictation, and any remaining accounts using the saved settings.

## Mac setup

1. Install [Wispr Flow](https://wisprflow.ai).
2. Install [ego lite](https://lite.ego.app/) so `ego-browser` is on your `PATH`.
3. Install [BlackHole 2ch](https://existential.audio/blackhole/) (virtual cable). Leave **your speakers** as the default output in System Settings.
4. Allow Wispr **Microphone** and **Accessibility**.
5. Xcode CLT for the audio helper: `xcode-select --install`
6. Node.js 20+ and Python 3.10+.
7. Build the isolated desktop test runtime after reviewing the note below:

```bash
python3 lib/prepare-isolated-runtime.py --prepare  # prepare a local copy for review
python3 lib/prepare-isolated-runtime.py --build    # sign and verify that copy
```

The installed Wispr app hardcodes its personal history path even with `--user-data-dir`. The test copy at `~/Applications/Wispr Flow.app` redirects history, legacy migration and logs into each test profile, requires an explicit profile argument, and is audited before recording. It uses an ad hoc outer signature without Hardened Runtime; nested signatures, Electron fuses, and the installed `/Applications/Wispr Flow.app` stay unchanged. An existing unrelated app at the test-copy path is never overwritten. The patch supports the verified installed build **1.6.1337**; updates require a storage-patch review before testing continues.

```bash
git clone https://github.com/geekyshubham/wispr-flow-referral-automation.git
cd wispr-flow-referral-automation
chmod +x wispr-* lib/*.sh lib/*.py
python3 lib/prepare-isolated-runtime.py --build
./wispr-run --accounts 2 --words 2100
```

## Cleanup (after the whole run)

When the last account is done — and also on crash / `./wispr-cleanup`:

- Extra isolated Wispr processes (and their helpers) are quit. Completed profiles are deleted; failed or interrupted profiles remain resumable.
  Cleanup **never** matches `~/Library/Application Support/Wispr Flow` (spaces in that path are handled; CI blocks regressions)
- Agent-owned ego-browser **Wispr task spaces** are closed; pages handed to you for a challenge stay open (ego lite itself stays open)
- Hands-free dictation is stopped; temp TTS files are removed
- Default **input** and **output** go back to Built-in (BlackHole is never left selected)
- Your main Wispr Flow app is relaunched (account data untouched)

You do not need to uninstall BlackHole; it only stays available as a device, not selected.

## hCaptcha

Wispr requires hCaptcha on **web email signup**. It cannot be turned off from this tool. There is no token to copy: the captcha is the **“I’m human” checkbox** (and sometimes a picture challenge) on the Wispr page inside **ego lite**.

The script clicks it when it can. If that fails, the log prints `HANDOFF:` and ego lite **leaves that window open** on the signup form. Watch:

```bash
tail -f data/wispr-run.log
```

Look for a line like:

```
HANDOFF:Please click the hCaptcha checkbox in ego-browser, then: ./wispr-resume wispr-account-1-...
```

Then:

1. Bring **ego lite** to the front (the Wispr signup tab is already on the password / captcha step).
2. Click the checkbox; solve the image challenge if one appears.
3. Run the command from the log:

```bash
./wispr-resume wispr-account-1-...
```

Login for an already-created account usually skips captcha. OAuth (Google/Apple) also skips it, but this automation stays on temp-mail so it never touches your Google account.

## Other commands

```bash
./wispr-next-inbox                    # prepare one next inbox in the background
./wispr-test 1 --no-dictation          # signup only
./wispr-resume [task-space]            # resume saved signup + complete remaining flow
./wispr-complete-flow email password   # isolated login + W words + cleanup
./wispr-cleanup                        # stop job + reset mic/speakers/Wispr
bash lib/restore-audio.sh builtin      # force Built-in mic/speakers
python3 lib/word-count.py profiles/<name>
```

`data/` and `profiles/` stay local (passwords, logs). Do not commit them.

Signup checks DNS for Wispr and the selected mail provider before allocating a mailbox or opening a browser. A lookup failure stops with status 69 and preserves the saved attempt; check the Mac network/VPN DNS settings before retrying.


## Resume and repeated runs

Every new signup uses an address absent from both signup and completion history. Used addresses in the prefetch cache are discarded. `--fresh` archives an unfinished attempt and starts a different mailbox; `./wispr-resume` only continues the current account’s verification or desktop work. A registered address is never submitted for a new signup.

An explicit referral rejection is terminal for that attempt. Both `./wispr-resume` and a new signup with the same code stop with status 76 while that rejection is saved, including when `--fresh` is supplied. An explicit `./wispr-run --fresh --referral DIFFERENT_CODE` archives the rejected attempt and starts a separate test with that code; changing the code alone does not resume or replace the saved account. Preserve rejected records for Wispr support; a different code does not establish eligibility or fix a service rejection.

Only one account-processing job can run at a time. Background startup confirms it acquired the job lock; `./wispr-cleanup` stops the owned process group and restores audio. Failures keep the same account and its remaining batch count. `./wispr-resume` resumes that state, preserves signup-only mode, and skips completed work. Profiles are keyed by the full email address, and completion records are updated instead of duplicated.

`MAIL_PROVIDER=maildrop ./wispr-next-inbox` keeps one unused Maildrop mailbox ready in `data/next-inbox.json`. It does not register another Wispr account. The next signup consumes it atomically. Mailbox selection and rate-limit updates use process locks and atomic checkpoints. Changing the provider discards incompatible queued mailboxes. Maildrop does not require mailbox registration; names are random and checked against signup history before use.

The automation disables the download page’s installer auto-start marker before page scripts execute. It uses the already installed/test app; normal manual download links stay available. Wispr web authentication is cleared before opening a new invitation, so the previous account cannot be redirected into that signup.

A completed word target proves dictation/upload succeeded. Referral association and rewards are separate service decisions; do not infer a credited referral from word count alone. New `wispr-run` batches require the service to report a referral association before dictation begins; a rejected or unconfirmed association stops that account for review and preserves its state.

`data/referral-diagnostic.json` stores the service result and a sanitized ordering trace for the website's signup/verification requests. It excludes passwords, verification codes and tokens. The trace observes the website; it does not alter authentication flags or referral eligibility. A valid code is separate from a successfully associated referral. The response alone does not identify IP filtering or prove a server ordering defect.

## Validation

```bash
npm test
```

The local suite covers account/batch resume, overlapping jobs, stale cleanup, mailbox locking and cooldowns, OTP parsing/sender validation, WorkOS token rotation, real history counts, and test-runtime integrity/isolation guards. It does not create live accounts. Live end-to-end runs still depend on Wispr/mail.tm availability and human CAPTCHA completion when requested.

Maildrop may greylist unfamiliar senders. Its default verification window is 16 minutes, with elapsed time and inbox message counts logged; `MAIL_WAIT_SECONDS` can override this. Old delayed codes are ignored and a fresh code is requested once when needed. Maildrop inboxes are public, so this tool uses unpredictable random names for generated test accounts.
