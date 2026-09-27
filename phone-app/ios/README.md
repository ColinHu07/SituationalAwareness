# Native iOS companion

## Quick multi-speaker caption test

Configure the existing Muse proxy in Settings, then choose **iPhone → Multi-speaker captions** on the home screen. On the separate **Live captions** screen, tap **Start** and allow microphone access. Up to three recent speaker rows (`P1`, `P2`, `P3`) remain visible together and update independently. A narrow self-introduction such as “I'm Sam” can replace that row's display label with the unique saved profile name; the underlying Muse label remains unchanged. Unresolved rows always keep their original `P` label. **Stop** clears captions, microphone, and all session-only identity links; backgrounding the app or using **Back** does the same. No camera or scene analysis runs in this test. Rows expire individually after 15 seconds without an update.

Run `npm install` and restart the backend for the new `/api/asr/realtime` WebSocket route. The server needs `MODEL_MODE=live`, `MUSE_API_KEY`, and the existing separate proxy token. This test uses Muse's actual speaker labels and stops with an error if realtime transcription is unavailable. It does not fabricate speaker labels from chunked transcription. Simultaneously visible rows do not guarantee recognition of both voices during overlapping speech. Translation is not included in this quick test.

The home screen keeps its **iPhone / Glasses** source buttons, People, Settings, camera, and conversation cues. Use **Back** to return from the caption test.

Expand **Timing & debug** on the caption screen to inspect timestamped capture, socket send, proxy forwarding, Muse progress, speaker/final events, and caption-state updates. Audio offsets and queue depths show where the stream falls behind; the round-trip measure covers phone ↔ proxy only. Event age is an estimate from the phone's audio callback clock and provider stream progress, not word-level latency or isolated model compute time. Phone and server elapsed timestamps use separate clocks. Audio/send summaries are throttled to once per second. **Share timing log** exports the last 200 metadata-only events; the same events appear under `CaptionTiming` in the native console. Stop keeps the log for inspection; Start resets it. Returning home discards the screen's in-memory log.

Open `Copilot.xcodeproj` in Xcode 26.6 or newer. The project pins Meta Wearables DAT **1.0.0** (`MWDATCore`, `MWDATCamera`, `MWDATDisplay`) and targets iOS 17.2+. No generated project step is needed. **iPhone** mode is the default and uses the built-in microphone with optional rear camera. **Meta glasses** retains camera/HFP capture and phone output. **Display glasses** uses low-rate video plus ambient PCM and shows social cues on the glasses. Physical capture/display behavior remains unverified; synthetic live Muse transport/schema checks are recorded in the root README.

## Run the simulator

1. Select the **Copilot** scheme and an iPhone simulator, then Run.
2. Select **Simulated demo** and keep **Local scripted model (no network)** enabled in Settings. No server or secret is required.
3. Confirm consent, tap **Start analyzing**, then **Quiet library**. The synthetic image fixture produces “This looks like a library. Keep your voice low.” without adding speech. Use **Analyze now** while the frame is fresh if a prior cue has started the cooldown.
4. Try **Group conversation**, then **Someone needs space**. The latter injects “I've had a rough day. I need some space.” and suggests listening/giving space based on those explicit words. Dismiss, Pause and Stop should remove old cues. These are labeled scripted fixtures, not Muse reasoning or speech recognition.
5. To exercise image/text transport through the proxy, disable the local scripted model and configure the proxy URL/token. Simulated input remains typed speech and a labeled synthetic image; fixture success is not evidence of real-world scene recognition.

From the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project phone-app/ios/Copilot.xcodeproj -scheme Copilot \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

# Choose an installed iPhone simulator from `xcrun simctl list devices available`.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project phone-app/ios/Copilot.xcodeproj -scheme Copilot \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  CODE_SIGNING_ALLOWED=NO test
```

DAT 1.0.0 adds `MockDisplayKit` previews and click injection. This app's native simulation is independent application code; it does not use that API or establish hardware coverage. The current audio guide does not expose deterministic mock PCM injection.

## Phone first (no glasses required)

1. Choose **iPhone**, optionally enable the rear camera, and keep the app foreground.
2. For permission/preview testing, enable **Capture test only (no uploads)**, confirm consent and **Start analyzing**. Verify the source rate/preview, then Stop. No transcript is fabricated.
3. Configure server-side `MODEL_MODE=live`, `MUSE_API_KEY`, and a separate `COPILOT_PROXY_TOKEN` in ignored `.env`. Enter only a reachable trusted HTTPS proxy URL and proxy token in app Settings. Simulator loopback HTTP is allowed; a real phone needs the server's reachable address.
4. Disable capture testing, confirm consent and Start. Phone mode explicitly selects the built-in microphone. Bounded WAV chunks go to Muse ASR; recognized words appear in **Captions**. Notes and suggestions stay separate.
5. Captions expire after 15 seconds and clear on Pause/Stop. Dismiss removes only the suggestion. Pause keeps wearer notes; Stop erases them and resets consent. Backgrounding pauses phone capture, including audio-only sessions; Resume is deliberate.

## Connect actual glasses

1. Set your Xcode **Development Team**, choose a unique bundle identifier, and install on an iPhone. Pair supported glasses in Meta AI, enable DAT Developer Mode as appropriate, and update firmware plus the DAT glasses app.
2. Developer Mode permits the sample-style `META_APP_ID` / `CLIENT_TOKEN` settings to remain unset. Outside Developer Mode, use the registered Wearables Developer Center app credentials and signing Team ID. The callback URL is `conversationcopilot://`. These credentials are separate from the Muse model key.
3. Select **Display glasses** or **Meta glasses**, then **Pair / register with Meta AI** and complete registration. The callback is handled through `Wearables.handleUrl`.
4. **Display glasses:** obtain **Camera and Audio Streaming** app approval for development/beta testing. Start checks/requests both DAT camera and microphone permissions and requests the app's iOS microphone permission. There is no HFP selection. Camera, direct ambient audio and Display share one session. Audio streaming is experimental and unavailable for production release channels.
5. **Regular Meta glasses:** use **Refresh Bluetooth audio inputs** and explicitly select the glasses by Bluetooth name. This route still uses HFP; camera attaches first, the selected HFP route settles for two seconds and is verified, then video starts. A lost route pauses capture; no phone mic is substituted.
6. Enable **Connection test only (no uploads)**, obtain consent, then **Start analyzing**. Check fresh frames and the reported source rate. In Display mode, Start also waits for ambient audio delivery. Use **Manual glasses display test**, physically verify the cue, Dismiss, and Stop. This does not require a model key or upload audio/images.
7. Disable connection testing, configure the trusted HTTPS proxy URL and proxy token, save, and **Check proxy**. The backend must report live mode for real capture. Confirm consent again, then Start.
8. Display controls are **Analyze now**, **Dismiss** when a cue exists, **Pause**, and **Stop**. Pause stops capture while retaining **Resume analysis / Stop** on the display; Resume creates a fresh DAT session. Stop clears the display then ends the session. System display/session interruption also pauses capture. Regular glasses show results on the phone; spoken output is not implemented.

The [pinned release notes](https://github.com/facebook/meta-wearables-dat-ios/blob/1.0.0/CHANGELOG.md) and [release README](https://github.com/facebook/meta-wearables-dat-ios/blob/1.0.0/README.md) describe DAT 1.0.0. The [audio guide](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/audio-streaming/SKILL.md) and [Display guide](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/display-access/SKILL.md), checked September 25, 2026, describe current setup. Guide files are absent from the release tag, so these two links intentionally use `main`.

## Native data and timing behavior

| Layer | Display surroundings mode |
|---|---|
| Glasses transport | Low-resolution `.hvc1` HEVC, requested 15 FPS, direct 16 kHz mono PCM |
| Local image sampling | One JPEG refreshed every 2 seconds; maximum dimension 640 pixels, quality 0.6 |
| Muse check eligibility | 8 seconds with recognized speech less than 30 seconds old; 20 seconds otherwise |
| Reduced power | 30-second checks in Low Power Mode or serious phone thermal state; critical thermal state pauses |
| Automatic cue cooldown | 30 seconds after a displayed or dismissed cue, independent of inference cadence |
| Cue lifetime | 8 seconds; ordinary expiry does not restart the cooldown |
| Evidence freshness | Submit speech ≤15 seconds old or a frame ≤10 seconds old. At response: speech ≤15 seconds or surroundings image ≤20 seconds |
| Manual check | Analyze now bypasses automatic timing, still requires fresh evidence and completed ASR |

These are provisional resource limits, not measured optimal settings. Camera/microphone stay on during the session; changing Muse cadence does not turn sensors off. The phone handles decoding, sampling, audio batching and scheduling. Muse performs ASR and image/text inference through the server; compute is not all on the phone or glasses. A displayed cue's cooldown can postpone an otherwise eligible periodic check.

- Regular glasses retain low-resolution 15 FPS HEVC and HFP; iPhone/regular-glasses local JPEG sampling remains configurable, default 8 seconds. No mode repeatedly calls `capturePhoto` or uploads the full video stream.
- Phone/HFP audio is converted from the actual route format to 16 kHz mono PCM16 WAV. Display requests 16 kHz mono PCM from DAT directly and uses the same bounded conversion/chunk pipeline. HFP's documented narrowband limitations remain specific to that route; resampling cannot restore fidelity.
- Provisional energy gating suppresses silence-only ASR uploads and emits roughly 1–6 second chunks. One ASR request is active; overlapping chunks drop instead of queuing. Energy can include fan/music/crowd noise. A failed ASR call pauses. Empty ASR in surroundings mode leaves visual analysis available and does not pretend that noise was speech.
- Spark receives recent recognized words, a fresh image, wearer notes and optional fresh audio-energy context. It never hears tone through the transcript. The metadata is uncalibrated dBFS/activity ratio, not sound classification or measured room loudness. Low energy does not prove a quiet room. Image evidence alone can support library etiquette; explicit words can support giving someone space. Face/mood/emotion inference is not implemented.
- Surroundings checks wait at least 1.5 seconds after recognized speech or session start. New recognized speech, a note edit, dismissal, pause, stop or failure invalidates old work. Raw ambient activity does not repeatedly invalidate Display surroundings cues. Phone/regular conversation mode retains its speech-activity gate.
- Rolling transcript: at most 60 seconds / 12 entries / 500 characters each. One sampled image and coarse audio context are retained. Raw media, transcript and context are not saved to app files. Pause clears capture buffers; Stop also clears wearer notes and consent. Tokens use device-only Keychain storage; DAT analytics/crash reporting are opted out.
- Cue requests are serialized with a 20-second HTTP timeout. Surroundings responses expire at 20 seconds, while conversation-mode response age remains limited to 10 seconds. Display eligibility requires confidence at least 0.8, a known cue type, no more than 90 characters / 14 words, and a cue absent from the last 20 normalized cues. Model confidence is not calibrated accuracy.
- Display send/clear operations are serialized and revision checked. Stale sends cannot become the final queued state. Physical clearing after a disconnect still cannot be acknowledged locally.
- Metrics include ASR/API time, successful upload bytes, evidence-to-phone-cue-ready time, stale/audio drops, displayed/distracting cues and returned usage cost estimates. These are not physical display acknowledgments or billing reconciliation.

## Hardware limits and pocket validation

**No physical camera/audio/display acceptance is claimed for this update.** Compilation and simulation cannot prove pairing, nearby-speaker transcription, synchronized transport quality, screen clearing after disconnect, pocket/background operation, thermal behavior or battery life. Current validation results are recorded in the root README; dated results below refer to their original versions.

The app declares background modes and uses HEVC/software decoding for glasses. A deliberately started glasses session may continue when pocketed, subject to iOS/device policy. iPhone mode deliberately pauses in the background. No timer circumvents a platform limit. Run the [hardware protocol](../../docs/DEMO.md), including nearby voices, steady ambient noise, display sleep and a locked-phone soak. Report a failed pocket test as failed.

## Source attribution

`../../regular-glasses/Sources/VideoFrameDecoder.swift` and its HEVC keyframe parser derive from Meta's official 0.9.0 CameraAccess sample, with copyright retained and modified stale-image behavior. The transport now uses DAT 1.0.0. Meta's developer terms are in `ThirdParty/Meta-DAT-LICENSE.txt`; the package retains its license/notice files.

## Previous verification (2026-09-23; before the phone-mode update)

- Simulator build: **passed**, Xcode 26.6, DAT 0.9.0, arm64/x86_64 simulator.
- Unsigned device build: **passed**, generic iOS arm64. This verifies compilation, not signing or installation.
- XCTest: **6 passed, 0 failed** on iPhone 17 Pro / iOS 26.5 simulator: consent gate, cue/dismiss/dedup, in-flight response invalidation on new speech, pause cancellation and erasure, transcript bounds and Stop erasure, PCM16 WAV format.
- Native app launched successfully in the simulator. The Mac was locked when UI inspection was attempted, so native visual UI inspection was **not performed**.
- Actual glasses, connected physical iPhone, live Muse transcription/model requests, and a phone-in-pocket session: **not verified**.

An initial simulator test exposed DAT singleton access after a failed SDK configure call. This was fixed: simulator runs never initialize DAT, and physical configuration failures surface as an error without touching an unconfigured singleton.

## September 25 update

Historical phone-first results before the Display surroundings update. See the root README for current build, test and provider checks.

Simulator and unsigned iPhone builds passed. **12 native tests passed, 0 failed**, and all **75 backend/session tests passed**. The app installed and launched in the iPhone 17 Pro simulator. Visual UI inspection of this update was not completed; live camera/microphone and authenticated Muse calls remain unverified.

See [reference comparison and phone acceptance](../../docs/REFERENCE_COMPARISON.md) and the root README for current validation. The three-second reference app was inspected, not copied; its generated “transcription” is not speech recognition. Current captions use our Meta ASR path.
