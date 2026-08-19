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

## Customize N and W

```bash
# 3 accounts, 2100 words each (keeps looping until all 3 are done)
./wispr-run --accounts 3 --words 2100

# same thing, positional args
./wispr-run 3 2100

# 1 account, 500 words
./wispr-run --accounts 1 --words 500

# env vars
ACCOUNTS=5 WORDS=2100 REFERRAL_CODE=SHUBHAM2270 ./wispr-run
```

If hCaptcha blocks a signup, that attempt is skipped and the loop tries a new inbox until N succeed (up to 4×N attempts).

## Mac setup

1. Install [Wispr Flow](https://wisprflow.ai).  
2. Install [ego lite](https://lite.ego.app/) so `ego-browser` is on your `PATH`.  
3. Install [BlackHole 2ch](https://existential.audio/blackhole/) (virtual cable). Leave **your speakers** as the default output in System Settings.  
4. Allow Wispr **Microphone** and **Accessibility**.  
5. Xcode CLT for the audio helper: `xcode-select --install`

```bash
git clone https://github.com/geekyshubham/wispr-flow-referral-automation.git
cd wispr-flow-referral-automation
chmod +x wispr-run wispr-test wispr-resume wispr-complete-flow lib/*.sh
./wispr-run --accounts 1 --words 2100
```

## Cleanup (mic / speakers)

After each account and on exit (`Ctrl+C` included):

- Isolated Wispr is quit and its profile folder is deleted  
- Default **input** and **output** devices are restored (BlackHole is never left as the system mic/speaker)  
- Your main Wispr Flow app is relaunched at the end of `./wispr-run`

You do not need to uninstall BlackHole; it only stays available as a device, not selected.

## Other commands

```bash
./wispr-test 1 --no-dictation          # signup only
./wispr-resume <task-space>            # after manual hCaptcha click
./wispr-complete-flow email password   # isolated login + W words + cleanup
bash lib/restore-audio.sh restore      # force-restore mic/speakers
python3 lib/word-count.py profiles/<name>
```

`data/` and `profiles/` stay local (passwords, logs). Do not commit them.
