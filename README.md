# Aside — an opt-in conversation copilot

**Live test:** the same installed iOS app offers **iPhone / Glasses** source selection and a shared camera-and-cue screen. Choose **Glasses → With display** for social cues on both screens and live captions on the phone. The iPhone source card also offers **Multi-speaker captions**, a separate Start/Stop test with up to three speaker rows. [Phone caption test setup](phone-app/ios/README.md#quick-multi-speaker-caption-test). [Step-by-step live glasses setup and test](docs/LIVE_GLASSES_TEST.md).

**Current context display:** live multi-speaker captions stay on the phone. Glasses show one readable cue. With conversation on, Muse is asked for a cue at a moment, not on a timer: someone else asks a question, uses a common indirect phrase, or finishes speaking and three seconds pass in silence, or the wearer selects **Analyze**. Each check sends the last three turns as text, labeled wearer or other, and its cue clears after 8 seconds. Scene-only Display mode keeps automatic camera cues on a 30-second timer. See [Display behavior](display-glasses/README.md) and [cues at the right moment](#september-26-cues-at-the-right-moment). Dated sections below describe earlier versions.

**Live face enrollment:** William's `0e1e120` changes are integrated with the context display above. Phone and glasses video share on-device face recognition. Confident new views of recognized friends can be saved automatically (up to three per conversation); a new addressed name plus one repeatedly observed unknown face can create a profile. **Settings → Save stills from video** controls automatic saving. Saved face crops persist in People and can be removed there.

A runnable native iOS companion with **iPhone**, **regular Meta glasses**, and **Display glasses** capture modes, a small credential-holding backend, and an explicitly simulated browser lab. The wearer starts deliberately, gets a brief social cue from the visible setting or recent recognized speech, and can dismiss, pause or stop.

**Implemented and locally tested; physical glasses acceptance remains unverified.** Pocket operation, nearby-speaker transcription and display wake behavior need the hardware acceptance test. Friend matching runs locally against enrolled photos; Muse does not identify faces or infer emotions/intentions. Current and historical verification results are separated below.

## FaceNet friend matching · September 26

Friend recognition now uses a bundled, on-device FaceNet identity model with shared eye alignment for photo enrollment and camera frames. It rejects ambiguous identities, group-photo enrollment and conflicting profile uploads. **Re-add existing face photos in People** to replace old Vision image features; names and notes remain available. [Model setup, migration and real-camera acceptance](docs/FACENET.md). **98 native tests and 124 backend tests passed**, with simulator and unsigned iPhone builds. Real-world accuracy and glasses latency remain unverified.

## Current merged app · September 26

William’s full People, groups, friend matching, presence, profile learning, scene labels and simpler UI are integrated with the working glasses flow. **Start glasses** opens lens controls; select **Start** on the glasses to capture. Display glasses default to automatic scene cues every **10 seconds** (**30** in reduced-power mode), with one recent image and available audio-energy context. No transcription runs in this default mode. Recommendations stay until the next result; lens **Pause** and **Stop** control capture.

Enable **Settings → Conversation and captions** before starting to add glasses speech transcription, name detection and profile learning. The People screen manages profiles and enrolled photos; proposed learned profile changes are reviewed before saving. The full merge passed **62 native tests** and **112 backend tests**, plus a signed iPhone build and a live synthetic Muse scene request. Real-world friend-matching accuracy remains to be tested. Earlier dated sections below describe historical builds.

## Captions alongside cues · September 26

The glasses now keep the **Heard:** caption visible alongside a separate **Cue:** suggestion. In conversation mode, captions are shown by default; Settings can hide them. Default glasses scene mode does not transcribe speech. Dismissing a cue preserves its caption, and Pause/Stop clears captured speech. The lens uses a short excerpt; the phone keeps a longer caption and recent transcript. These are app-owned, completed-chunk captions, with up to six seconds of capture plus ASR latency and possible dropped chunks while ASR is busy. This change does not add word-by-word streaming or reuse Meta's built-in Live Captions. **40 native tests passed** for the earlier caption-specific build, including simultaneous caption/cue updates and lifecycle checks. Combined lens readability and nearby-speaker accuracy still require hardware testing. See [SDK research and next tests](docs/research-captions.md).

## Display surroundings update · September 25

Choose **Display glasses**, confirm consent, and tap **Start analyzing** on the phone. DAT **1.0.0** sends low-resolution **2 FPS HEVC video plus 16 kHz mono ambient PCM** to the phone in one camera stream. Display mode does not select an HFP microphone. Regular glasses retain their HFP input and phone output.

The phone keeps one JPEG refreshed every **2 seconds**, batches audio for Muse ASR, and asks Muse Spark about the fresh image and recognized words. Checks are eligible every **8 seconds** with recognized speech less than 30 seconds old, **20 seconds** otherwise, or **30 seconds** in Low Power Mode / serious thermal state. Critical phone thermal state pauses capture. A separate **30-second cue cooldown** avoids repeated automatic nudges; each cue lasts **8 seconds**. These are provisional settings, not measured optimal performance.

Camera and microphone stay active until **Pause** or **Stop**. On the glasses, **Analyze now** requests a check without waiting for automatic timing; **Dismiss**, **Pause**, **Stop**, and paused **Resume analysis** give control back to the wearer. Captions are optional and secondary to the social cue. The phone coordinates capture and scheduling; Muse inference runs through the backend rather than on the glasses.

A fresh image alone can support “This looks like a library. Keep your voice low.” Explicit speech such as “I need some space” can support giving someone a moment. Audio-energy metadata does not identify sounds, measure room loudness, or infer tone/mood. Raw ambient noise does not repeatedly invalidate surroundings checks; recognized speech updates conversation evidence. No raw audio/video files are saved.

Ambient streaming is an **experimental development/beta capability** requiring **Camera and Audio Streaming** app approval and camera/microphone permissions. It cannot currently be published to production release channels. See [Display setup](display-glasses/README.md), the [pinned DAT 1.0.0 changelog](https://github.com/facebook/meta-wearables-dat-ios/blob/1.0.0/CHANGELOG.md), and the [current official audio guide](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/audio-streaming/SKILL.md) checked September 25. The release tag omits guide files, so the guide link uses `main`.

In **Simulated demo**, try **Quiet library**, **Group conversation**, and **Someone needs space** with the local scripted model. The images and words are labeled fixtures; these demonstrate app behavior without claiming live recognition. This update has **22 passing native tests**, **101 passing backend tests**, and successful simulator/unsigned iPhone builds. Standalone simulator launch, library/group/supportive cues, Pause and Stop were verified through the UI. A missing runtime framework search path was fixed for standalone launches. Synthetic live Muse image/text requests returned valid structured cues in **9.51–10.09 seconds**; a one-second synthetic silence clip returned an empty ASR transcript in **1.14 seconds**. These verify API transport/schema, not recognition accuracy or camera-to-glasses latency. Actual glasses behavior remains unverified.

Live testing exposed a reasoning-token truncation at 1,024 tokens. The provider now allows 4,096 combined reasoning/output tokens and uses minimal reasoning for surroundings. Cue HTTP timeout is 20 seconds. Images must be at most 10 seconds old when submitted; scene responses are discarded when their submitted image exceeds 20 seconds. Speech freshness stays 15 seconds, and new recognized speech or session controls cancel pending work. One request at a time means actual check cadence also depends on model latency.

## Phone-first update · September 25

The three device folders are **[phone-app/](phone-app/)**, **[regular-glasses/](regular-glasses/)** and **[display-glasses/](display-glasses/)**. The phone folder owns the runnable Xcode project; it compiles the glasses source modules into the same companion. Shared backend, protocol, tests and browser preview remain at the root.

The reference [Read the Room repository](https://github.com/max-lee-dev/sbu-hacks-read-the-room) uses Gemini image analysis, ElevenLabs narration and NeuralSeek guidance. Its “transcription” field is scene narration, not recognized speech. [Full code review and provider mapping](docs/REFERENCE_COMPARISON.md).

The iOS app now offers three real capture paths plus a labeled demo. **iPhone** uses the phone's built-in mic and optional rear camera without initializing DAT. **Meta glasses** uses their camera/HFP and shows results on the phone. **Display glasses** uses direct ambient PCM and renders social cues, with optional captions, on the glasses. Regular-glasses spoken output is not implemented.

The phone screen separates **Captions** (completed ASR speech chunks), **Your notes** (wearer-authored), and **AI suggestion**. Captions do not wait for the suggestion cooldown and survive suggestion dismissal. They are not word-by-word partial streaming. Camera/audio input and live Meta calls still need real-device validation.

Start with **Capture test only (no uploads)** on a real iPhone to verify permissions and preview without a model key. Then configure the Muse proxy, turn capture testing off, and follow [phone acceptance steps](docs/REFERENCE_COMPARISON.md#phone-acceptance-sequence). Phone mode pauses in the background; keep it open for the first test.

## Run now — no API key, installs or glasses needed

Requires Node 22+; this workspace was tested with Node 22.3.0.

```sh
npm start
```

Open [the local lab](http://127.0.0.1:8787). Keep **Simulated conversation** selected, confirm the consent checkbox, click **Start session**, then **An unclear question**. After a natural pause the simulated display offers “Ask what they meant by Friday.” **Change subject**, **Dismiss cue**, **Pause**, and **Stop** clear stale content. **Run scripted demo** provides a short repeatable sequence. Model and device simulation are explicitly labeled.

```sh
npm test
npm run benchmark
```

The backend uses Node built-ins; there are no npm runtime dependencies. The browser lab pauses when hidden and is not a phone-in-pocket substitute.

## Native iPhone companion

Open `phone-app/ios/Copilot.xcodeproj` in Xcode. The project pins the official Meta DAT **1.0.0** package and includes HEVC decoding, ambient PCM for Display glasses, explicit HFP selection for regular glasses, WAV transcription, social cues and local simulation. See [iOS setup](phone-app/ios/README.md) for registration, developer mode, signing, firmware and proxy configuration.

Build without changing the Mac's globally selected developer tools:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project phone-app/ios/Copilot.xcodeproj -scheme Copilot \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath artifacts/DerivedData CODE_SIGNING_ALLOWED=NO build
```

The app starts in **iPhone** mode. Choose **Simulated demo** with a **local scripted provider** to try it without a backend or hardware. Our simulated display is not Meta Mock Device Kit validation of Display glasses. The separate **Connection test only (no uploads)** mode exercises the selected camera/audio path and a manual Display cue before configuring Muse. For actual hardware, use [the two-person demo protocol](docs/DEMO.md).

## Enable live Muse Spark and ASR

```sh
cp .env.example .env
```

Edit this ignored file locally:

```dotenv
MODEL_MODE=live
MUSE_API_KEY=your_actual_meta_model_key
COPILOT_PROXY_TOKEN=an_independent_random_secret_at_least_32_characters
```

Generate the separate proxy token with `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`. Enter only that **proxy token** in the companion or browser lab. Never distribute `MUSE_API_KEY`. Restart `npm start` after configuration changes. An invalid/ineligible key causes an explicit failure; there is no live-to-mock fallback.

For an iOS simulator, the loopback endpoint is `http://127.0.0.1:8787`. A physical phone needs a reachable **trusted HTTPS** proxy endpoint; its own `127.0.0.1` does not point at this Mac. The Node development server does not terminate TLS. Use a secured deployment/reverse proxy, set `HOST` appropriately if needed, and disable request-body/token logging in that infrastructure. Native non-loopback HTTP is rejected. This repository does not publish a service automatically.

The live provider uses documented `muse-spark-1.3` image + text requests with a strict five-field schema. Audio uses the separate `muse-voice-transcribe-1.0` HTTP API. Spark gets recognized text and images, not the raw soundtrack or audible tone. Display PCM arrives at the requested ASR sample rate; regular-glasses HFP is resampled without improving fidelity. No live video socket or sound-event classifier is implemented.

To test real image transport after capturing a consented frame:

```sh
npm run smoke:live -- --image /absolute/path/to/consented-sampled-frame.jpg --consented
```

This sends the supplied image with an abstention probe and reports only transport/schema success and usage metrics. It requires a real key and has no stock-image substitution; it does not establish cue accuracy or prove the frame came from glasses. For explicit development fallback in the browser, select **Browser camera + manual / mic input**. Camera/mic capture requires a secure browser context (localhost qualifies). Browser microphone recording is per-button six-second chunks, while native capture is continuous and bounded.

## Phone update verification · September 25

Historical phone-first results before the Display surroundings update; device and credential availability below describe that earlier run.

- **12 native tests passed**, including caption lifetime, separate notes, phone defaults, foreground pause, and no-upload capture mode.
- **75 backend/session tests passed**; browser JavaScript syntax check passed.
- Simulator and unsigned physical-iPhone builds succeeded; the app installed and launched in the iPhone 17 Pro simulator.
- This update's visual UI inspection was not completed: the simulator UI exposed a different device window, and the in-app browser inspection timed out. The earlier browser results below apply to the September 23 version.
- Physical phone capture, glasses, and authenticated Muse requests remain **unverified** without a connected device and model credential.

## Initial verification · September 23

| Area | Result on 2026-09-23 |
|---|---|
| Session/backend/provider-contract tests | **75 passed**, using actual local HTTP and clearly mocked provider responses |
| Browser controls | Consent gate, Start, Friday cue, manual cue, dismiss, topic change, Pause and Escape/Stop exercised in the running UI |
| Local benchmark | 30 simulated HTTP requests; p50 **1.22 ms**, p95 **4.16 ms**; no HTTP failures |
| Scripted cue evaluation | 0 false / 0 missed across 30 deterministic fixture cases; **not a Muse accuracy estimate** |
| Late response after subject change | Suppressed in tests and benchmark |
| Native SDK integration | DAT 0.9.0; simulator and unsigned physical-iOS builds succeeded; **6 native tests passed**, app launched in simulator |
| Native visual inspection | Not completed: Mac locked; native state tested through XCTest, browser UI inspected separately |
| Actual camera + mic + display | **Not verified** — no connected glasses/phone |
| Actual Muse request / transcription | **Not verified** — no local API key supplied |
| Pocket mode, partner audio, display wake | **Not verified** — hardware acceptance gates |
| Live latency, cost, battery, thermal behavior, human distraction | **Unmeasured** |

Machine-readable local results are in [benchmark.json](docs/benchmark.json). Its tiny text-only requests are not representative of image/audio bandwidth. Native/browser counters measure upload payloads, ASR/API times, returned usage costs and stale drops; physical display latency requires observation on glasses. Missing/canceled request billing remains unknown. Mark distracting cues and export metrics without conversation content.

The dated results above describe the earlier conversation-only version. Display mode now uses the sampling and scheduling policy documented in the Display surroundings update; browser and regular-glasses timing remain distinct. Local mock timing does not establish optimal live behavior.

## Important platform findings

- DAT 1.0.0 adds synchronized experimental camera PCM and a mock Display preview. Direct ambient PCM is used for Display mode; its nearby-speaker quality still requires testing. Regular glasses retain the documented 8 kHz HFP route, which may suppress a partner's voice.
- DAT has display support, but its display dims/sleeps after idle time; guaranteed wake-on-cue is unverified.
- HEVC is the documented iOS background camera route. Complete locked-phone camera/audio/network/display operation still needs testing.
- No fixed current DAT three-minute camera limit was established; no speculative timed restart is implemented.
- Standard Muse content is not used for training under the current terms, but **not zero-retention by default**. The app keeps bounded content in memory and clears it; cancellation cannot recall data already sent upstream.

See [dated research and sources](docs/RESEARCH.md), [architecture and alternatives](docs/ARCHITECTURE.md), [model API details](docs/research-model.md), [wearables findings](docs/research-wearables.md), and [demo/failure test script](docs/DEMO.md). Some SDK legal pages required login; their exact bystander/retention clauses remain a documented unresolved check.

## Project map

| Path | Purpose |
|---|---|
| `phone-app/` | Native Swift companion, phone capture, Xcode project and native tests |
| `regular-glasses/` | DAT session/camera transport and HEVC decoding, reused by Display mode |
| `display-glasses/` | Glasses caption/suggestion rendering and display controls |
| `server/` | Authenticated task-specific model/ASR proxy, validation, no content logging |
| `shared/` | Strict cue schema and tested browser lifecycle policy |
| `web/` | Local simulator and explicit browser input fallback |
| `tests/` | Session, protocol, audio, provider and HTTP failure cases |
| `scripts/` | Repeatable local benchmark and opt-in live image probe |
| `docs/` | Research, architecture, acceptance script and recorded measurements |

The HEVC decoder is adapted from Meta's official sample; attribution and license are retained under `phone-app/ios/ThirdParty/`.

## September 26: persistent cues and tone coaching

William's `daba7fe` update is integrated with the existing phone and glasses flows. Cues persist until replaced or dismissed, with a five-second minimum dwell and a ten-second quiet period after dismissal. Checks run every three seconds near recent speech, five seconds otherwise, four seconds in scene-only Display mode, or fifteen seconds in reduced-power mode; requests remain serialized. The phone keeps up to eight short model summaries as session memory and sends the current cue so unchanged advice need not be redrawn. Native cue confidence eligibility is now 0.6. These settings supersede older timing descriptions elsewhere in this repository.

**Coach my wording** adds a separate recovery suggestion for potentially blunt speech. **That was me** calibrates a microphone-level heuristic; it is separate from the provider's speaker labels in multi-speaker captions. The backend adds `/api/tone` and allows up to 120 requests per minute.

The integration preserves realtime multi-speaker phone captions and timing diagnostics, the camera preview frame-rate fix, glasses scene/conversation switching, wristband controls, no-upload capture testing, and conversation learning when glasses streaming stops. Physical hardware and live-provider behavior still require validation.

Merge validation: all 124 Node tests passed. Native simulator testing was attempted twice but blocked by local disk exhaustion while Xcode wrote module/index caches (`No space left on device`); native test results are not confirmed for this merge.

## September 26: cues at the right moment

Conversation cues no longer run on a 10-second timer. A check is sent with a `trigger` naming the moment:

| Trigger | When it fires |
|---|---|
| `question` | Someone else finishes a turn that ends in a question mark |
| `indirect` | Someone else uses a phrase listed in `phone-app/ios/Copilot/IndirectPhrases.swift` |
| `stuck` | Someone else finishes a turn, then 3 seconds pass with no speech |
| `manual` | The wearer selects **Analyze** |

- **The wearer's own turns never prompt a check, and no tap is needed.** The glasses microphone sits next to the wearer's mouth, so their voice is the loudest. The app measures the speech level of each live-caption turn and averages it per speaker label. The loudest label becomes the wearer once it has two turns and averages at least 6 dB above every other voice heard. It is re-evaluated only when another label, with two turns, averages 6 dB above it.
- **The wearer is kept for the whole session.** Caption labels are numbered afresh when captions restart after a pause, so the app keeps the wearer's level and matches the voice again on its first turn. Stop ends the session and forgets it.
- **Until the wearer is found, no `question` or `stuck` check is sent.** Indirect phrases and **Analyze** still work. **Settings → My voice → That was me** is an optional override that marks the most recent caption as the wearer's. The six-second chunk fallback uses the level found in the session, or the saved voice level.
- **Checks are small.** Only the last eight turns are sent, as text, labeled `wearer` or `other`. The newest turn is the one to respond to; the earlier ones show the topic. The most recent summary from a scene check in the same session is sent too, if it is under five minutes old. No image is sent. Optional **Settings → About me** text is sent as `aboutMe` so a suggested answer can be specific.
- **Stale replies are dropped.** If anyone speaks while a reply is in flight, it is never shown. A cue needs a confidence of at least 0.8, has no minimum dwell, and clears after 8 seconds. **Analyze** always answers, with "Nothing to add" when nothing fits.
- **Scene-only Display mode** keeps its camera cues and its prompt. Its timer is now 30 seconds. Modes with conversation on no longer send camera images to Muse.
- **Backend.** `POST /api/cue` accepts `trigger` and an optional `aboutMe` of up to 500 characters. Conversation checks use the new `SYSTEM_PROMPT` and a five-field schema. `meaning` is a valid cue type. Clients that send no trigger get `manual`, `question` or `stuck` from the request. The mock provider abstains on ordinary speech instead of offering generic listening advice.

These settings supersede older timing descriptions elsewhere in this repository. Live Muse latency and cue quality with the new prompt have not been measured.

### Early question checks and cue timing

With live captions, a question is checked before its turn is finalized. A partial caption of someone else's turn sends the `question` check once its words have not changed for 300 ms and it looks like a question, and its cue is shown as soon as it returns. A partial looks like a question when it ends in a question mark (two words or more), or has at least four words and opens with a question word such as what, how, where, when, why, who, "are you", "do you", "did you", "have you", "can you" or "would you". The rules are in `phone-app/ios/Copilot/SpeculativeCue.swift`.

- **One early check per turn, never on the wearer's turns.** The voice must carry a caption label, the wearer's own label must be known, and the two must differ. An unlabeled partial waits for its label.
- **When the turn is finalized, the words are compared.** Punctuation, case and filler words are not a change, and nothing more is sent. If the words changed and are still a question, the check runs again and its cue replaces the early one. If the turn was the wearer's own, or was not a question, the early cue is cleared.
- **Chunked transcription has no partial captions**, so it keeps the finished-turn checks only.

**Caption timing** on the phone now shows five steps for the last cue, each measured from the end of speech: final received, request sent, response received and cue shown. A minus sign means the step happened before the speech ended, which an early check can do. The shared timing log has one line per step and a `Cue timing` line per cue. It records times only, never words.

The conversation prompt also tells the model to abstain when the cue it would suggest does not fit the topic of the last two turns. It must not state places, names, facts or recommendations that are not in the turns or in `aboutMe`; when a cue would need one it suggests a general reply or a question instead. For an indirect phrase it explains the exact phrase that was said, with several example phrases and meanings in the prompt rather than one.

### Optional Grok provider for conversation checks

Set `XAI_API_KEY` in the ignored `.env` to send conversation checks to xAI's `grok-4.20-non-reasoning` (override with `XAI_MODEL`). The prompt, the five-field strict schema and the text-only request are the same; the output limit is 256 tokens. Scene checks, tone, learning and transcription stay on Muse, and `MUSE_API_KEY` is still required in live mode. With no `XAI_API_KEY`, conversation checks use Muse as before.

If the Grok request fails, returns an unusable answer, or has not answered after 3 seconds, the same request is sent once to Muse. If Muse fails too, no cue is shown. A check the client cancelled is not retried. Scene checks are never retried.

With the key set, the last eight turns, the most recent summary and the optional `aboutMe` text are sent to xAI instead of Meta. Review xAI's data terms before using it with real conversations.

Every `/api/cue` response carries `metrics.provider`, `metrics.model` and `metrics.apiMs`, and the server log line for each cue request ends with `provider=… model=… apiMs=…`. `provider` is the one that answered. After a fallback the metrics also carry `fallbackFrom`, `fallbackReason` (`timeout`, `rate_limited`, `unavailable` or `error`) and `fallbackAfterMs`, the log line ends with `fallback=xai:timeout:3001ms`, and `apiMs` covers both attempts. `GET /api/health` reports `conversationModel`.
