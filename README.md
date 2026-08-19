# Wispr Flow referral automation

Mac tool that creates **N** temp-mail Wispr accounts on your referral link, then simulates **W** dictated words on each account until all N are done. Isolated Wispr is used so your personal login is untouched. When the run finishes (or crashes), **system mic and speakers are restored** and your normal Wispr app is relaunched.

## Entire flow (per account, looped N times)

```
mail.tm inbox
  → signup at https://wisprflow.ai/r?SHUBHAM2270 (ego-browser, cookies cleared)
  → email verification link
  → isolated Wispr desktop login
  → BlackHole loopback dictation until W words
  → quit isolated instance, restore Built-in mic/speakers
repeat until N accounts have W words each
  → relaunch your normal Wispr Flow
```

Web-only signup stays **Pending / Under 2000 words**. Desktop dictation is required.

## Customize N and W (runs in the background)

```bash
# 2 accounts, 2100 words each — returns immediately, job keeps going
./wispr-run --accounts 2 --words 2100

./wispr-run 2 2100                 # same
./wispr-run --accounts 1 --words 500
tail -f data/wispr-run.log         # watch progress
./wispr-run 2 2100 --foreground    # run in this terminal instead
./wispr-cleanup                    # abort + full reset anytime
```

Dictation uses a hidden isolated Wispr and plays TTS into BlackHole, not your speakers. After **all** accounts finish (or you stop it), it resets: isolated instances quit, temp profiles deleted, Built-in mic/speakers selected, your normal Wispr relaunched.

During the job your personal Wispr is paused so deeplinks hit the isolated instance; it comes back in the final cleanup. Signup may still pop ego-browser if hCaptcha needs a click (`./wispr-resume <task-space>`).

## Mac setup

1. Install [Wispr Flow](https://wisprflow.ai).  
2. Install [ego lite](https://lite.ego.app/) so `ego-browser` is on your `PATH`.  
3. Install [BlackHole 2ch](https://existential.audio/blackhole/) (virtual cable). Leave **your speakers** as the default output in System Settings.  
4. Allow Wispr **Microphone** and **Accessibility**.  
5. Xcode CLT for the audio helper: `xcode-select --install`

```bash
git clone https://github.com/geekyshubham/wispr-flow-referral-automation.git
cd wispr-flow-referral-automation
chmod +x wispr-run wispr-cleanup wispr-test wispr-resume wispr-complete-flow lib/*.sh
./wispr-run --accounts 2 --words 2100
```

## Cleanup (after the whole run)

When the last account is done — and also on crash / `./wispr-cleanup`:

- Extra isolated Wispr processes (and their helpers) are quit; `profiles/` is deleted  
  Cleanup **never** matches `~/Library/Application Support/Wispr Flow` (spaces in that path are handled; CI blocks regressions)  
- ego-browser **Wispr task spaces** are closed (ego lite itself stays open)  
- Hands-free dictation is stopped; temp TTS files are removed  
- Default **input** and **output** go back to Built-in (BlackHole is never left selected)  
- Your main Wispr Flow app is relaunched (account data untouched)

You do not need to uninstall BlackHole; it only stays available as a device, not selected.

## hCaptcha

Wispr requires hCaptcha on **web email signup**. It cannot be turned off from this tool. The script clicks the checkbox when it can; if the token never fills, that attempt hands off for a human click:

```bash
./wispr-resume <task-space>
```

Login for an already-created account does not use captcha. OAuth (Google/Apple) also skips it, but this automation stays on temp-mail so it never touches your Google account.

## Other commands

```bash
./wispr-test 1 --no-dictation          # signup only
./wispr-resume <task-space>            # after manual hCaptcha click
./wispr-complete-flow email password   # isolated login + W words + cleanup
./wispr-cleanup                        # stop job + reset mic/speakers/Wispr
bash lib/restore-audio.sh builtin      # force Built-in mic/speakers
python3 lib/word-count.py profiles/<name>
```

`data/` and `profiles/` stay local (passwords, logs). Do not commit them.
