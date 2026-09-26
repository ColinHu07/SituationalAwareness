# Native iOS companion

Open `Copilot.xcodeproj` in Xcode 26.6 or newer. The project pins Meta Wearables DAT **0.9.0** (`MWDATCore`, `MWDATCamera`, `MWDATDisplay`) and targets iOS 17.2+. No XcodeGen, CocoaPods, or generated project step is needed. The app now starts in **iPhone** mode: the built-in microphone and optional rear camera work independently of DAT. Choose **Meta glasses** for regular glasses camera/HFP with phone output, or **Display glasses** for camera/HFP and caption/cue display in one `DeviceSession`. Hardware paths still require real-device validation.

## Run the simulator

1. Select the **Copilot** scheme and an iPhone simulator, then Run.
2. Select **Simulated demo** on the main screen; keep **Local scripted model** enabled in Settings. No secret or server is needed. The default iPhone mode needs real phone inputs, so choose the demo explicitly in Simulator.
3. Agree to the consent toggle, Start, then Add line or Ordering example. Captions appear independently of notes and suggestions. After quiet time, a supported fixture produces a labeled simulated suggestion. Change subject while a request is pending, dismiss, pause, and stop.
4. To exercise the proxy, run the root project's backend, disable **Local scripted model**, and enter `http://127.0.0.1:8787` (or its configured port) and the proxy bearer token. The native simulator then sends typed speech plus an explicitly synthetic image. It does not access a camera or microphone.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ios/Copilot.xcodeproj -scheme Copilot \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

# Choose an installed iPhone simulator from `xcrun simctl list devices available`.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ios/Copilot.xcodeproj -scheme Copilot \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  CODE_SIGNING_ALLOWED=NO test
```

The app's display simulation is original application code. Meta's MockDeviceKit does not support Display glasses and is not used to claim Display hardware coverage.

## Phone first (no glasses required)

1. Select **iPhone** on the main screen. Choose whether to include the rear camera; audio-only is explicit.
2. For permission/preview testing, enable **Capture test only (no uploads)**. Confirm consent, Start, grant microphone/camera permissions, verify source rate and camera preview, then Stop. No transcript is fabricated in this mode.
3. Set the server's `MODEL_MODE=live`, `MUSE_API_KEY`, and separate `COPILOT_PROXY_TOKEN` in the ignored `.env`. In app Settings, enter a reachable trusted HTTPS proxy URL and the proxy token. Simulator loopback HTTP is allowed; a real phone needs the server's HTTPS address.
4. Disable Capture test only, confirm consent and Start. The app explicitly selects the **built-in phone microphone**, rather than silently using a headset. Speech is sent in bounded WAV chunks to Meta ASR; actual recognized text appears under **Captions**. User notes and generated suggestions are separate.
5. Captions are completed speech chunks, **not partial word-by-word streaming**. They expire after 15 seconds and are cleared on Pause/Stop. Dismissing an AI suggestion leaves captions/notes intact. Pause retains wearer notes; Stop erases them.
6. Keep the phone app foreground. Backgrounding pauses phone capture, including audio-only sessions; Resume is deliberate. The glasses-specific pocket research does not establish phone-camera background support.

## Connect actual glasses

1. In Xcode set your **Development Team**, choose a unique bundle identifier, and install to a connected iPhone. Pair the Meta Ray-Ban Display with the current Meta AI companion app and enable DAT Developer Mode according to Meta's current setup guide. Ensure glasses firmware and the DAT glasses app are current.
2. In Developer Mode the sample-style `META_APP_ID` / `CLIENT_TOKEN` build settings may remain unset. Outside Developer Mode, configure those values using the registered Wearables Developer Center app plus your signing Team ID. The callback URL is `conversationcopilot://`. These are DAT app credentials, not the Muse Spark key.
3. Select **Meta glasses** or **Display glasses** on the main screen. Tap **Pair / register with Meta AI** and complete the flow. Meta AI callbacks are handled through `Wearables.handleUrl`.
4. Tap **Refresh Bluetooth audio inputs** and explicitly choose the glasses by their Bluetooth name. HFP ports cannot be reliably mapped to DAT device identifiers, so the wearer must choose the correct glasses. No phone microphone fallback exists.
5. For the first vertical slice enable **Connection test only (no uploads)**, obtain everyone's consent, then Start. This attaches camera/display, selects and verifies the glasses HFP route, receives camera frames, and enables **Manual glasses display test**, without requiring a model key or sending any data. Speech buffers are discarded. Camera/display/HFP errors still pause capture.
6. For the full conversation, Stop, turn the connection test off, enter your trusted **HTTPS** backend URL and `COPILOT_PROXY_TOKEN`, save to Keychain, and Check proxy. The server must report live mode; mock mode cannot transcribe hardware audio. Start only after explaining processing and receiving consent. Store the actual Muse key only on the server.
7. Regular glasses do not attach a display capability: results appear on the phone and spoken output is not yet implemented. For Display glasses, native display controls are focusable DAT Buttons: Help, Dismiss when a cue exists, Pause, and Stop. Dismiss and the 8-second timeout remove the cue and return to a small control view. Pause stops microphone/camera and retains a display-only Resume/Stop view; Resume creates a fresh DAT session. Root back/system display interruption also pauses capture. Stop clears the display then ends the device session.

Phone mode avoids initializing DAT entirely. For the glasses modes, the initial camera permission flow can open Meta AI. Start can take the official microphone guide's **2-second route-settle delay**, plus connection time. Capture ordering is add camera → select/verify HFP → start camera stream. This avoids switching Bluetooth profiles after video has started. Audio route changes and interruptions pause; they do not automatically turn recording back on.

## Native data and timing behavior

- `.hvc1`, low resolution, 15 FPS from the glasses. Software HEVC decoding follows Meta's current sample, modified so decode failures return nil rather than retimestamping an old image. App uploads only an optional JPEG sample, normally every **8 seconds**, configurable 3–30 seconds, resized to at most 640 pixels and quality 0.6. No `capturePhoto` call is used.
- Real microphone format is read from `AVAudioEngine` and displayed. Phone mode selects builtInMic; glasses modes require the chosen HFP route. The guide documents 8 kHz mono HFP; actual device rates have **not been measured**. An `AVAudioConverter` converts the selected route to **16 kHz mono PCM16 WAV** for `muse-voice-transcribe-1.0`; resampling does not restore lost fidelity.
- Provisional energy VAD suppresses silence uploads and batches about 1–6 seconds. There is one ASR request at a time; a new chunk is dropped under load. An empty transcription clears prior speech; a failed transcription pauses. No prerecorded substitute is used. Partner speech may be strongly suppressed by the glasses' wearer-focused beamforming.
- Rolling transcript: ≤60 seconds, ≤12 entries, ≤500 characters each. A single sampled image is retained, and only included if ≤10 seconds old. Audio, transcript, image and context are not written to files. Pause erases transcript/frame/audio buffers; Stop also erases wearer-entered context. The proxy bearer token is in Keychain with device-only accessibility after first unlock. Proxy URL is in preferences. DAT analytics and crash reporting are opted out in Info.plist.
- One cue request at a time; 10-second HTTP request timeout. Every detected speech buffer, transcript change, context edit, dismiss, pause, stop, or connection failure invalidates old cue work. Results require ≥1.5 seconds quiet, newest speech transcribed, transcript age ≤15 seconds, confidence ≥0.8, ≤90 characters / 14 words, and a known cue type. Automatic cooldown: 30 seconds. Last 20 cues are deduplicated. The 8-second display lifetime is separate from the freshness check.
- Display writes are serialized. A clear/control update queues after an in-flight send, so a stale send cannot become the final visible state. Camera/microphone stop immediately; a remote display clear still depends on the glasses link. If disconnected, physical clearing cannot be acknowledged. Reconnect requires deliberate Resume.
- Measurements include API time, ASR time, successful JSON request bytes, speech-end-to-phone-cue-ready time, stale drops, dropped audio chunks, cues and wearer-marked distracting cues. Provider-reported estimated cue + ASR costs are accumulated; missing reported usage is “Unavailable.” Cancelled or failed API calls may be billed without returned usage, so this estimate is not an invoice. Phone timing is not a measured capture-to-glasses-display acknowledgment.

## Hardware limits and pocket validation

**No actual glasses or connected iPhone were available to this build session, including the September 25 phone-mode update.** Compilation and simulator checks cannot prove device pairing, HFP quality, simultaneous camera/HFP/display, screen clearing after disconnect, pocket/background operation, thermal behavior, battery life, or physical gesture behavior.

The app declares audio and Bluetooth background modes and uses HEVC/software decoding for glasses. Meta's current CameraAccess UI sample intentionally ends its preview session on background entry, while its decoder/audio code discusses background operation. Glasses modes keep an explicitly started session active, but iOS and device policies may pause it. **iPhone mode deliberately pauses on background entry.** There is no timer that tries to circumvent a platform duration limit. Test glasses with a locked phone / pocket for ≥10 minutes, device sleep, notification interruption, route loss and reconnect on actual hardware using `docs/DEMO.md`. If background capture stops, the honest result is a failed pocket test—not a successful live demo.

## Source attribution

`Copilot/VideoFrameDecoder.swift` and its HEVC keyframe parser derive from Meta's official 0.9.0 CameraAccess sample, with copyright retained and modified stale-image behavior. Meta's developer terms are in `ThirdParty/Meta-DAT-LICENSE.txt`. The Swift package retains its own license/notice files. Other app code in this directory was written for this prototype.

## Previous verification (2026-09-23; before the phone-mode update)

- Simulator build: **passed**, Xcode 26.6, DAT 0.9.0, arm64/x86_64 simulator.
- Unsigned device build: **passed**, generic iOS arm64. This verifies compilation, not signing or installation.
- XCTest: **6 passed, 0 failed** on iPhone 17 Pro / iOS 26.5 simulator: consent gate, cue/dismiss/dedup, in-flight response invalidation on new speech, pause cancellation and erasure, transcript bounds and Stop erasure, PCM16 WAV format.
- Native app launched successfully in the simulator. The Mac was locked when UI inspection was attempted, so native visual UI inspection was **not performed**.
- Actual glasses, connected physical iPhone, live Muse transcription/model requests, and a phone-in-pocket session: **not verified**.

An initial simulator test exposed DAT singleton access after a failed SDK configure call. This was fixed: simulator runs never initialize DAT, and physical configuration failures surface as an error without touching an unconfigured singleton.

## September 25 update

Simulator and unsigned iPhone builds passed. **12 native tests passed, 0 failed**, and all **75 backend/session tests passed**. The app installed and launched in the iPhone 17 Pro simulator. Visual UI inspection of this update was not completed; live camera/microphone and authenticated Muse calls remain unverified.

See [reference comparison and phone acceptance](../docs/REFERENCE_COMPARISON.md) and the root README for current validation. The three-second reference app was inspected, not copied; its generated “transcription” is not speech recognition. Current captions use our Meta ASR path.
