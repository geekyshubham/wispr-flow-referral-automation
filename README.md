# Wispr Flow tester

End-to-end Mac automation for Wispr Flow referral accounts:

1. Create a **mail.tm** temp inbox  
2. Sign up at `https://wisprflow.ai/r?SHUBHAM2270` in an isolated **ego-browser** session  
3. Confirm the email verification link  
4. Log into a **separate Wispr Flow profile** (your personal Google account is not used)  
5. Dictate until **2100+ words** via hands-free deeplink + BlackHole audio loopback (background, no TextEdit)

## Entire flow

```
mail.tm account
    -> ego-browser signup (Turnstile; hCaptcha may need one click)
    -> verification link from inbox
    -> isolated Wispr desktop login (session injected)
    -> wispr-flow://start-hands-free
    -> macOS `say` audio played only into BlackHole 2ch (Wispr mic)
    -> wispr-flow://stop-hands-free
    -> repeat chunks until totalWords >= 2100
    -> optional cleanup of isolated profile + relaunch your main Wispr
```

Referral dashboards stay **Pending / Under 2000 words** until this desktop dictation completes and syncs. Web signup alone is not enough.

## Mac setup

### 1. Apps

- [Wispr Flow](https://wisprflow.ai) desktop app  
- [ego lite](https://lite.ego.app/) with the `ego-browser` CLI on your `PATH`  
  (`which ego-browser` should print a path)

### 2. BlackHole (virtual audio cable)

Dictation is silent on your speakers. TTS is rendered to a file, then played **only** into **BlackHole 2ch**, which Wispr uses as its microphone.

1. Install [BlackHole 2ch](https://existential.audio/blackhole/)  
2. System Settings → Sound: leave **your speakers** as the default output  
3. First run will point the **isolated** Wispr mic at `BlackHole 2ch (Virtual)`

You should not hear the dictation script, and it should not steal focus (`open -g` + hidden isolated window).

### 3. Permissions

Grant **Wispr Flow**:

- Microphone  
- Accessibility (for paste/helper; word count still works from ASR if paste has nowhere to go)

Do **not** use your main Wispr window for this test. The tools pause the default Wispr process so deeplinks (`wispr-flow://…`) hit the isolated instance.

### 4. Clone and run

```bash
git clone https://github.com/Geekyshubham/wispr-flow-tester.git
cd wispr-flow-tester
chmod +x wispr-run wispr-test wispr-resume wispr-complete-flow lib/*.sh
```

No Node `npm install` is required for the ego-browser path.

## How to use

### Full pipeline (what you usually want)

```bash
# One account: temp mail → signup → verify → isolated app → 2100 words
./wispr-run 1

# Three accounts
./wispr-run 3
```

Optional:

```bash
export REFERRAL_CODE=SHUBHAM2270   # default
export TARGET_WORDS=2100           # default
```

### Step by step

```bash
# Signup only (no dictation)
./wispr-test 1 --no-dictation

# If ego-browser hands off for hCaptcha: click the checkbox, then:
./wispr-resume <task-space-name>

# Isolated login + dictation for an already-verified account
./wispr-complete-flow you@emalupe.com 'YourPassword'

# Dictation only (isolated profile already exists)
bash lib/dictate-fast.sh profiles/<local-part-of-email> 2100

# Word count
python3 lib/word-count.py profiles/<local-part-of-email>
```

hCaptcha is the unreliable step. Turnstile usually auto-fills. If signup stops, finish the checkbox in ego-browser and run `wispr-resume`.

## Background dictation details

`lib/dictate-fast.sh`:

- ~280-word chunks at ~230 wpm  
- Compiles `lib/play-to-device.bin` once (needs Xcode CLT: `xcode-select --install`)  
- Caches AIFF files under `data/tts-cache/` (gitignored)  
- Does **not** open TextEdit  
- Does **not** change your default output device  
- Hides the isolated Wispr window  

Your **main** Wispr is paused for the dictation window so the URL handler does not talk to the wrong account. It is relaunched at the end of `wispr-complete-flow`.

## Layout

| Path | Role |
|------|------|
| `wispr-run` | Full pipeline |
| `wispr-test` | mail.tm + referral signup |
| `wispr-resume` | Finish signup after manual hCaptcha |
| `wispr-complete-flow` | Isolated login + 2100-word loop + cleanup |
| `lib/dictate-fast.sh` | Fast BlackHole / hands-free loop |
| `lib/dictation-text.txt` | Spoken source text |

`data/` and `profiles/` are local-only (credentials, logs, Electron profile). Do not commit them.

## Notes

- Isolated profile path: `profiles/<email-local-part>/`  
- Stats are read from that profile’s `config.json` (`prefs.cache.statistics.totalWords`)  
- Restarting isolated Wispr can reset local stats from the server; the fast loop avoids relaunching between chunks  
- This is a personal test harness for a referral program, not an official Wispr product  
