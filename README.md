# Aside — an opt-in conversation copilot

A runnable native iOS companion with **iPhone**, **regular Meta glasses**, and **Display glasses** capture modes, a small credential-holding backend, and an explicitly simulated browser lab. The wearer starts deliberately, gets a brief cue only when supported by recent conversation, and can dismiss, pause or stop.

**Implemented and locally tested; not yet verified on glasses or the authenticated Muse API.** No phone was connected and no model key was provided during this run. Pocket operation, partner transcription and display wake behavior need the hardware acceptance test. This is not a medical product and does not identify faces or infer emotions/intentions.

## Phone-first update · September 25

The three device folders are **[phone-app/](phone-app/)**, **[regular-glasses/](regular-glasses/)** and **[display-glasses/](display-glasses/)**. The phone folder owns the runnable Xcode project; it compiles the glasses source modules into the same companion. Shared backend, protocol, tests and browser preview remain at the root.

The reference [Read the Room repository](https://github.com/max-lee-dev/sbu-hacks-read-the-room) uses Gemini image analysis, ElevenLabs narration and NeuralSeek guidance. Its “transcription” field is scene narration, not recognized speech. [Full code review and provider mapping](docs/REFERENCE_COMPARISON.md).

The iOS app now offers three real capture paths plus a labeled demo. **iPhone** uses the phone's built-in mic and optional rear camera without initializing DAT. **Meta glasses** uses their camera/HFP and shows results on the phone. **Display glasses** additionally renders captions and suggestions on the glasses. Regular-glasses spoken output is not implemented.

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

Open `phone-app/ios/Copilot.xcodeproj` in Xcode. The project pins the official Meta DAT **0.9.0** package and includes camera/HEVC decoding, a shared camera/display session, explicit Bluetooth HFP input selection, WAV transcription, cue controls and local simulation. See [iOS setup](phone-app/ios/README.md) for registration, developer mode, signing, firmware and proxy configuration.

Build without changing the Mac's globally selected developer tools:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project phone-app/ios/Copilot.xcodeproj -scheme Copilot \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath artifacts/DerivedData CODE_SIGNING_ALLOWED=NO build
```

The app starts in **iPhone** mode. Choose **Simulated demo** with a **local scripted provider** to try it without a backend or hardware. Our simulated display is not Meta Mock Device Kit validation of Display glasses. The separate **Connection test only (no uploads)** mode exercises actual camera/HFP/display and a manual cue before configuring Muse. For actual hardware, use [the two-person demo protocol](docs/DEMO.md).

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

The live provider uses documented `muse-spark-1.3` image + text requests with a strict five-field schema. Audio uses the separate `muse-voice-transcribe-1.0` HTTP API. It does not use a presumed real-time video socket. HFP audio is resampled to the ASR format, not improved in fidelity.

To test real image transport after capturing a consented frame:

```sh
npm run smoke:live -- --image /absolute/path/to/consented-sampled-frame.jpg --consented
```

This sends the supplied image with an abstention probe and reports only transport/schema success and usage metrics. It requires a real key and has no stock-image substitution; it does not establish cue accuracy or prove the frame came from glasses. For explicit development fallback in the browser, select **Browser camera + manual / mic input**. Camera/mic capture requires a secure browser context (localhost qualifies). Browser microphone recording is per-button six-second chunks, while native capture is continuous and bounded.

## Phone update verification · September 25

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

The initial 5-second browser / 8-second native frame samplers, 60-second transcript, 1.5-second silence gate, 30-second automatic cooldown and 8-second cue expiry are **provisional conservative settings**. Local mock timing does not justify claiming an optimal real-time configuration. Tune using live repeated measurements.

## Important platform findings

- The documented HFP route is 8 kHz mono and may suppress the partner's voice. Successful transcription of the wearer alone does not satisfy the two-person demo.
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
