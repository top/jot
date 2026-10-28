<div align="center">

<img src="docs/images/icon.png" width="128" alt="Jot">

# Jot

**OpenAI-compatible dictation. Hold a key. Speak. It types.**

Dictation for macOS with your own ASR and optional text-cleanup model.

<sub>Created by [Ammaar Reshi](https://x.com/ammaar) · Apache 2.0 licensed</sub>

</div>

This is not an officially supported Google product.

---

## What it is

Start from the menu bar, speak, and stop with the recording pill. Your result is
copied, ready to paste. Optionally grant Accessibility to use the global `fn`
key and insert text into the app you were already using. Enable optional LLM
cleanup for filler removal and formatting. No account to make.

<img width="640" height="294" alt="Jot preview" src="https://github.com/user-attachments/assets/669efea9-dbfe-4174-a8fe-748aab818f14" />


It is deliberately small: a menu bar icon, a pill at the bottom of your screen
while you talk, and a History window that proves nothing was ever lost.

## The three gestures

| Gesture | What happens |
| --- | --- |
| **Hold `fn`** | Records while held. Release and the text lands at your cursor. |
| **`fn` + tap `Space`** | Hands-free: keeps recording after you let go. Tap `fn` to finish. |
| **`Esc`** | Cancels. Anything over 10 seconds is still kept in History. |

The key is rebindable in Settings → General if `fn` is spoken for.
These global gestures require Accessibility. Without it, use **Start Hands-Free
Dictation** in the menu bar and the pill's stop button.

## What makes it different

**Optional text cleanup.** A configured LLM can remove filler words, apply
self-corrections and match app tone. Enable it in Settings → Dictation.
If cleanup fails or changes too much, Jot keeps the original transcript.

**It never loses your words.** Audio goes to disk from the first millisecond, so
a crash, a `kill -9`, or a flat battery costs you nothing — the recording is
recovered on next launch. Offline, dictations queue and land when you reconnect.
Every failure is retryable from History. Release the key mid-word and it keeps
listening until you actually stop.

**It is private by architecture.** Your voice goes from your Mac straight to the
OpenAI-compatible service with *your* key. No Jot server, no account, no analytics, no
screenshots, no keystroke logging — one network host, and you can read every
line of the code that talks to it. See [PRIVACY.md](docs/PRIVACY.md).

**Your jargon, spelled right.** Names and product terms go in the Dictionary and
ride along with the audio as recognition hints. Their effect depends on the
ASR service; explicit misspelling replacements are always applied locally.

## Install

1. Download the latest `Jot-x.y.z-UNNOTARIZED.dmg` from [Releases](../../releases/latest).
2. Drag Jot into **Applications** and launch it from there — apps run from a
   mounted disk image are sandboxed by macOS and the permissions you grant will
   not stick.

<div align="center">
<img src="docs/images/installer.png" width="480" alt="Drag Jot to Applications">
</div>

Setup takes about two minutes and the app walks you through it:

1. **Configure Base URL, API Key and ASR Model.** The URL includes the API
  prefix, for example `http://localhost:8000/v1`. The key stays in Keychain.
  LLM Model is optional. You can skip configuration and add it later in
  Settings → Advanced.
2. **Allow the microphone** — say hello and it advances by itself.
3. **Optionally allow Accessibility** for the global dictation key and automatic
  input. Choose **Skip for now** to use menu-bar dictation and manual paste.
4. **Start dictating** from the menu bar, or hold `fn` when authorized.

Each completed foreground dictation replaces the clipboard with its result,
including when automatic input succeeds. The previous clipboard is not restored;
the result stays available until your next copy. Disable **Automatically insert
text** in Settings → Dictation to use manual paste even with Accessibility.
If the target app changes, Jot does not insert into the newly focused app.
Secure input remains an exception: in-flight results stay in History only.
Recovery and queued retries also remain in History without changing the clipboard.

ASR uses `POST /audio/transcriptions`; optional cleanup uses
`POST /chat/completions`. Both share the configured Base URL and key. Model IDs
are entered manually, with no built-in provider or model fallback. A Qwen3-ASR
service must expose the transcription endpoint; Chat-only APIs need a different
adapter and are not supported. For an unauthenticated local server, use a
placeholder key such as `EMPTY` if the server accepts it.

### LLM thinking

**Enable thinking**, below LLM Model, is unchecked by default, including for
existing configurations. It affects only optional LLM cleanup, not ASR.
**Thinking control** defaults to **Do not send (server default)** when no control
was previously saved, preserving compatibility with existing APIs and models.
Previously saved explicit controls are retained. Select a supported control to
enable the thinking checkbox, then save:

| Control | Disabled | Enabled |
| --- | --- | --- |
| Do not send (default) | No parameter; server default applies | Checkbox unavailable |
| vLLM / Qwen | `chat_template_kwargs: {"enable_thinking": false}` | `chat_template_kwargs: {"enable_thinking": true}` |
| DashScope | `enable_thinking: false` | `enable_thinking: true` |
| OpenAI | `reasoning_effort: "none"` | `reasoning_effort: "medium"` |

Only the selected control is sent. The model and server must support that
control; thinking-only models cannot be made non-thinking by this option.
For models that reject `reasoning_effort` or its `none` value, such as GPT-4o
or older reasoning models, use **Do not send**. This mode does not guarantee
thinking is disabled; it deliberately leaves inference behavior to the server.
Jot does not infer support from model names, hide reasoning as a substitute for
disabling it, or remove rejected parameters and retry. If cleanup is rejected,
times out, or fails validation, the original transcript is used with local
dictionary replacements. Cleanup allows 20 seconds when thinking is explicitly
enabled with a control, otherwise 5 seconds. A server that silently ignores controls cannot provide
a no-thinking guarantee; verify support with your provider.

Accessibility changes are checked every second while Jot is running, including
when it is only in the menu bar. Granting or revoking access does not require
activating a Jot window or restarting the app.

Protocol references: [vLLM](https://docs.vllm.ai/en/latest/features/reasoning_outputs/),
[DashScope](https://help.aliyun.com/zh/model-studio/deep-thinking),
[OpenAI](https://developers.openai.com/api/docs/guides/reasoning).

Connection checking uses `/models` and does not prove that either model works.
Unsupported or unreachable checks allow saving an unverified configuration.
Service costs and data handling depend on your provider. Recordings retain the
existing 10-minute limit. See [release instructions](docs/RELEASING.md) for
opening an unnotarized build.

## How it works

```
fn down ─▶ capture (CAF on disk from t=0) ─▶ fn up ─▶ WAV ─▶ ASR API
                                                                    │
  clipboard + optional cursor input ◀─ [validate ◀─ tone pass] ───────┘
                                              (optional, off by default)
                                                    │
                                              History (SQLite)
```

A few decisions worth knowing about, because they are what make it feel solid:

- **The capture graph is pre-warmed while idle**, so a key press only pays
  `engine.start()` — 20-40ms instead of 75-150ms. Preparing is not recording: no
  audio flows and no mic indicator appears until you actually hold the key.
- **The mic drains one buffer past the stop**, because the audio tap only
  delivers whole ~100ms chunks and tearing down immediately threw away the tail
  of your last word.
- **Results stay on the clipboard** unless secure input is active. When automatic
  input is enabled and authorized, Jot tries Accessibility insertion, then a
  guarded paste, leaving the result on the clipboard either way. It never
  blind-pastes into an app that stole focus mid-flight.
- **A validation gate** guards the optional tone pass, catching the classic failure where the model *answers*
  your audio instead of transcribing it, and falls back to the raw transcript.
- **The paths that can lose words are tested.** `JotCore` is a headless Swift
  package holding the state machine, hotkey grammar, audio, transcription,
  formatting, insertion and history — so the failure modes above are exercised
  without launching the app.

The full design specs — including the failure matrix the reliability work is
built from — are in [docs/design/](docs/design/).

## Development

Requires macOS 14+, Xcode 16+, and [xcodegen](https://github.com/yonaskolb/XcodeGen).
The `.xcodeproj` is generated, not checked in.

```bash
brew install xcodegen
./scripts/build.sh          # xcodegen generate + xcodebuild
./scripts/test.sh           # swift test on JotCore
open Jot.xcodeproj          # or work in Xcode
```

Builds sign ad-hoc, so a clean clone needs no Apple account, certificate,
or team membership. The fork uses bundle ID `org.ie9.app`.

```
App/            menu bar item, HUD pill, windows, design tokens, icon + sounds
JotCore/        all engine logic, headless and testable
  HotkeyEngine/     CGEventTap + the pure hold/lock/cancel grammar
  AudioEngine/      crash-safe CAF capture, device changes, prewarming
  TranscriptionClient/  OpenAI-compatible calls, timeouts, retries, WAV
  FormattingPipeline/   cleanup prompt, validation gate, dictionary rules
  InsertionEngine/      the AX → paste → clipboard ladder
  HistoryStore/         GRDB index, recovery, retry queue, retention
scripts/        build, test, icon, DMG, release
docs/           privacy, releasing, design specs, research
```

Useful while hacking:

```bash
# every surface is reachable headlessly
open "jot://settings/about"      # or /general /dictation /privacy /advanced
open "jot://history"  "jot://dictionary"  "jot://onboarding/5"

# watch it work
log show --last 5m --info --predicate 'subsystem == "com.ammaar.jot"'
```

Transcript text is logged as `private` and never appears in those logs.

### Releasing

Push a `v*` tag to build and publish an unnotarized universal DMG through GitHub
Actions, or run the Release workflow manually to download a test artifact.
No Apple Developer account or signing secrets are needed. Gatekeeper may block
the first launch. See [docs/RELEASING.md](docs/RELEASING.md) for installation
and release instructions.

## License

Apache License 2.0 — see [LICENSE](LICENSE). Bundled fonts (Google Sans Flex,
Google Sans Code) are SIL OFL 1.1. The earcons are original works covered by the
same Apache 2.0 license. Details in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
