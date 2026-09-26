# Wearables platform research

Initial research **2026-09-23**, corrected for DAT **1.0.0 on 2026-09-25**. This is the platform appendix to `RESEARCH.md`. “Verified” means checked against official documentation, release notes or binary API interfaces, **not tested on the user's glasses**. No hardware success is claimed.

## September 25 correction: direct camera audio and Display mocks

The original 0.9.0 findings below said DAT lacked microphone buffers and Mock Device Kit lacked Display support. Both statements are obsolete for **1.0.0**, released September 24. The companion now pins `1.0.0` at commit `1f38beecba83c4c8b5e343540f9cd615323ab19a`. [Pinned changelog](https://github.com/facebook/meta-wearables-dat-ios/blob/1.0.0/CHANGELOG.md), [pinned README](https://github.com/facebook/meta-wearables-dat-ios/blob/1.0.0/README.md).

DAT 1.0.0 introduces experimental `StreamConfiguration.audioCodec` and `Stream.audioFramePublisher`. Direct PCM accompanies camera video, with `pcmBuffer` and a presentation timestamp. This app requests **16 kHz mono PCM** and **low-resolution 2 FPS HEVC** for Display glasses. The phone maps audio/video timestamps to the session clock, consumes bounded PCM chunks, and cancels the audio listener before stopping Camera. Audio shares the camera stream's lifecycle/errors. HFP selection remains only for regular glasses.

The current [official audio guide](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/audio-streaming/SKILL.md), checked September 25, requires **Camera and Audio Streaming** app approval plus `.camera` and `.microphone` runtime permission. It allows development/beta testing and excludes production release channels. The app also requests iOS microphone permission. The guide supports 16,000 / 44,100 / 48,000 Hz PCM and directs consumers to use presentation timestamps. These are documented API capabilities, not measured nearby-speaker fidelity.

DAT 1.0.0 also adds `MockDisplayKit` with a phone preview and click injection for `.metaRayBanDisplay`. The [current Display guide](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/display-access/SKILL.md), checked September 25, demonstrates this path. The app's own demo remains separate synthetic application code. MockDeviceKit can negotiate audio-enabled streaming but the audio guide does not expose deterministic PCM-frame injection, so mock audio delivery is not an acceptance substitute.

The **1.0.0 tag contains binaries, README and changelog but omits the plugin guide files**. Release links above are version pinned; guide links intentionally use `main` and have an inspection date. Do not use nonexistent `blob/1.0.0/plugins/...` links or treat changing `main` docs as immutable release evidence.

The implementation keeps a fresh JPEG locally every 2 seconds and requests Muse checks at 8 seconds with recognized speech less than 30 seconds old, 20 seconds without recent recognized speech, or 30 seconds under Low Power Mode / serious phone thermal state. Critical phone thermal state pauses. A separate 30-second cue cooldown and 8-second lifetime limit display interruptions. **Analyze now** bypasses automatic timing while retaining freshness checks. Camera and microphone remain active until Pause/Stop; the phone schedules the work and Muse performs ASR/image-text inference through the backend.

Ambient PCM is transcribed; Spark receives recognized text, a fresh image and optional coarse energy metadata. It does not directly classify sounds or hear tone in that request. Energy is uncalibrated and cannot prove a quiet room. Raw fan/music/crowd activity does not reset surroundings timing; recognized speech does. A fresh library image may support etiquette without a transcript, while explicit requests for space may support a social response. Mood inference from faces or voices is excluded.

## Earlier sources and reproducibility · September 23

| Source | Version/date inspected | Result |
|---|---|---|
| [Official iOS repository](https://github.com/facebook/meta-wearables-dat-ios) | Main commit `225f64ff1617e7acc8c407bb8d3ee132f7263d00`, 2026-08-03 | SDK 0.9.0, CameraAccess and DisplayAccess source inspected |
| [Official Android repository](https://github.com/facebook/meta-wearables-dat-android) | Main commit `974e05c569da8be01c0c9ce8bc5bc79b73ff8540`, 2026-09-14 | SDK 0.9.0; dependencies migrated to Maven Central |
| [iOS changelog](https://github.com/facebook/meta-wearables-dat-ios/blob/225f64ff1617e7acc8c407bb8d3ee132f7263d00/CHANGELOG.md) / [Android changelog](https://github.com/facebook/meta-wearables-dat-android/blob/974e05c569da8be01c0c9ce8bc5bc79b73ff8540/CHANGELOG.md) | Releases through 0.9.0 | Current API names and behavior changes verified |
| [DAT overview](https://wearables.developer.meta.com/docs/develop/dat/), [build overview](https://wearables.developer.meta.com/docs/develop/dat/build-overview/), [microphone guide](https://wearables.developer.meta.com/docs/develop/dat/microphones-and-speakers/) | Retrieved 2026-09-23 through official docs MCP | Web fetch returned login page; MCP supplied substantive current documentation |
| [Public Wearables docs MCP](https://mcp.developer.meta.com/wearables), [MCP guide](https://wearables.developer.meta.com/docs/develop/dat/ai-assisted-mcp/) | Server 1.0.0; protocol `2025-06-18` | Unauthenticated JSON-RPC `initialize`, `tools/list`, `tools/call` worked; used `search_dat_docs` |
| [Display launch announcement](https://developers.meta.com/blog/build-for-display-glasses/) | 2026-05-14 | Native iOS/Android display access and Neural Band interaction announced |
| [Current official FAQ](https://developers.meta.com/wearables/faq/) | Retrieved 2026-09-23 | Developer Preview, publishing restrictions, display mock limitations |

The MCP was queried for microphone/HFP sample rate and ordering, camera configuration and duration, session lifecycle, display sleep/gestures/clear, background behavior, privacy/consent, and SDK telemetry. It returns documentation sections, not a promise of exhaustive search. A missing duration limit in search results is therefore **not proof of unlimited operation**. The official repository knowledge-base files were also read as reference material. This table records the original 0.9.0 inspection; the 1.0.0 release correction above takes precedence for current Display/audio behavior.

## Platform choice

**Use native iOS DAT 1.0.0 for this prototype.** The Display path uses camera PCM; regular glasses retain the phone OS HFP input. The original platform comparison was conducted against 0.9.0. iOS is selected because this workspace's host has Xcode 26.6 and a registered, currently offline iPhone; no connected Android device was found. This is a toolchain/device fit, not a guarantee that iOS hardware is universally more reliable.

The project targets **iOS 17.2+** and uses Xcode 26.6. The original 0.9.0 DisplayAccess prerequisites were Xcode 26.4+, Swift 6.3+. Its modules are `MWDATCore`, `MWDATCamera`, `MWDATDisplay`, and `MWDATMockDevice`. Android 0.9.0 is now downloadable from Maven Central (`com.meta.wearable:mwdat-*`) without the older GitHub package token setup. Both have real DisplayAccess samples. [iOS sample](https://github.com/facebook/meta-wearables-dat-ios/tree/225f64ff1617e7acc8c407bb8d3ee132f7263d00/samples/DisplayAccess), [Android README](https://github.com/facebook/meta-wearables-dat-android/blob/974e05c569da8be01c0c9ce8bc5bc79b73ff8540/README.md).

The native path is appropriate for simultaneous sensors and display. Web Apps support display and gesture interactions, but the official FAQ's supported sensor list does not establish camera/HFP capture for Web Apps. The web simulator is development tooling, not evidence of sensor access on the glasses.

## Camera and lifecycle

The current iOS sequence is `Wearables.configure()` → registration and required camera/audio permissions → select a display-capable device → create/start one `DeviceSession` → wait for `.started` → `session.addCamera(config:)` → obtain `camera.stream` → listen to video/state/error publishers → `stream.start()`. `DeviceSession.addStream` was **removed in 0.9.0**. Display is a second capability on the same session; don't create competing sessions.

Verified camera configuration:

| Setting | Current documented values |
|---|---|
| Resolution | Low 360×640; medium 504×896; high 720×1280 |
| Requested FPS | 2, 7, 15, 24, 30 |
| iOS delivery | `VideoFrame`, with raw `CMSampleBuffer`; raw image conversion or compressed HEVC (`.hvc1`) |
| Stream lifecycle | waiting/starting/streaming/paused/stopping/stopped states |
| Still photo | `capturePhoto(format: .jpeg)` during active stream; result arrives through publisher |

The docs describe adaptive resolution and frame-rate reduction under Bluetooth contention and also list requested 2/7 FPS while saying the adaptive ladder does not fall below 15 FPS. Do not treat that combination as an observed performance guarantee; measure actual received timestamps/FPS. Configuring the device stream is separate from sampling a much smaller number of frames for the model. [Current camera reference source](https://github.com/facebook/meta-wearables-dat-ios/blob/225f64ff1617e7acc8c407bb8d3ee132f7263d00/plugins/mwdat-ios/skills/camera-streaming/SKILL.md).

**Pocket/background:** iOS `.raw` delivery pauses when backgrounded; `.hvc1` was added in SDK 0.5.0 for background compressed streaming. The 0.9 CameraAccess sample supports background recording, but deliberately stops an ordinary preview when backgrounded. Its HEVC decoder disables hardware decoding to survive backgrounding. Copying preview lifecycle wholesale would break a pocket copilot. Background entitlement configuration, audio capture, software decoding, and model/network work still need an actual locked-phone soak test; “compressed stream works in background” alone does not validate the whole application. [CameraViewModel](https://github.com/facebook/meta-wearables-dat-ios/blob/225f64ff1617e7acc8c407bb8d3ee132f7263d00/samples/CameraAccess/CameraAccess/ViewModels/CameraViewModel.swift), [decoder](https://github.com/facebook/meta-wearables-dat-ios/blob/225f64ff1617e7acc8c407bb8d3ee132f7263d00/samples/CameraAccess/CameraAccess/Media/VideoFrameDecoder.swift).

The sample decoder can return its last good image while awaiting a keyframe. A copilot must not stamp that held image as newly captured; preserve original frame time or drop it. Decode off the UI thread, bound pending work, and invalidate stale results on pause/stop or session change.

**Pause/reconnect:** A device-initiated pause keeps the connection but stops frame delivery. Wait for `.started` or `.stopped`; do not restart while paused. A stopped session is terminal: clean up and create a new session after availability returns. Closing hinges disconnects Bluetooth and stops the session; reopening restores Bluetooth but does not restart it. Doff/hinge cases, removal of app registration, competing experiences, calls, and connection loss must invalidate pending cues. [Lifecycle reference](https://github.com/facebook/meta-wearables-dat-ios/blob/225f64ff1617e7acc8c407bb8d3ee132f7263d00/plugins/mwdat-ios/skills/session-lifecycle/SKILL.md).

**Three-minute claim:** No fixed three-minute DAT streaming limit was found in current guides, official sample code, or changelogs. No automatic “restart every 179 seconds” workaround is justified. The public repository also contains a first-hand **community** report of an 18-minute iOS camera/HFP run on 0.9.0, which is evidence against assuming a universal three-minute cap, not verification of this app or these glasses. Actual maximum safe duration remains hardware/firmware/thermal dependent and unmeasured. [Report dated 2026-09-19](https://github.com/facebook/meta-wearables-dat-ios/issues/260#issuecomment-5745643051).

**Thermal/battery:** SDK device state exposes `ThermalLevel`. DAT 1.0.0 renamed prior stream errors to `.thermalHot`, `.peakPowerLimit` and `.batteryLow`, and added `.audioStreamingError`; these pause this app through the stream error path. Phone serious thermal state slows surroundings checks, critical state pauses them. Do not repeatedly reconnect through these conditions. No defensible minutes-of-battery estimate or thermal threshold was found for this combined workload. Record model/firmware, elapsed time, actual FPS, connection errors, thermal transitions, and before/after battery during a 10–15 minute initial soak test.

## Microphone and transcription implications

**Historical HFP route, still used by regular-glasses mode:** the September 23 microphone guide described **8 kHz mono HFP**, using iOS `AVAudioSession`/`AVAudioEngine` or Android `AudioManager`/`AudioRecord`. The former claim that DAT has no microphone-buffer API was correct for the inspected 0.9.0 API but is superseded by 1.0.0 camera PCM above. HFP is bidirectional; A2DP is output-only at higher quality. Activating HFP replaces A2DP and reduces output fidelity. The phone may expose resampled PCM at another rate: log both the negotiated route and actual buffer format, and don't interpret a 44.1 kHz software buffer or AAC output file as 44.1 kHz acoustic information.

The HFP guide documents an ordering constraint for the regular-glasses route:

1. Add the DAT camera/stream to the started session.
2. Request OS microphone permission, configure/start HFP, and select the glasses' input.
3. Wait for routing to settle (the example waits two seconds), then verify `currentRoute.inputs` really contains the selected Bluetooth HFP input.
4. Only then start the DAT video stream.

Use `.playAndRecord`, `.default`, `.allowBluetoothHFP` (older SDKs use `.allowBluetooth`), `availableInputs`, `setPreferredInput`, and an input-node tap. Multiple Bluetooth inputs can exist: merely selecting the first HFP port is not an identity guarantee. Display the chosen port and require the route to stay on it. On route loss, interrupt/stop and report it; do not silently switch to the phone mic.

**The guide explicitly says HFP beamforming isolates the wearer's voice and suppresses other speakers and ambience.** It can support wearer speech recognition, but faithful partner transcription is an unresolved requirement. An 8 kHz stream also lacks higher-frequency speech detail. Evaluate partner and wearer word accuracy separately, at realistic distance/noise. If partner audio is weak, abstain or use an explicitly selected, consented phone/external microphone fallback; a pocketed phone microphone may also perform poorly. Do not describe scripted text as captured/transcribed speech.

Official sample source has a trap: Android 0.9 CameraAccess records `AudioSource.MIC` at 44.1 kHz, i.e. a phone-microphone example, while iOS permits HFP but does not force the specific glasses input. “Sound in video” in the changelog therefore does not prove correct glasses audio routing. [Android audio sample](https://github.com/facebook/meta-wearables-dat-android/blob/974e05c569da8be01c0c9ce8bc5bc79b73ff8540/samples/CameraAccess/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/stream/AudioInputHandler.kt), [iOS audio sample](https://github.com/facebook/meta-wearables-dat-ios/blob/225f64ff1617e7acc8c407bb8d3ee132f7263d00/samples/CameraAccess/CameraAccess/Media/AudioInputHandler.swift).

Concurrent capture is documented, but reliability is not uniform. Public issue #260 reports HFP/still-photo failures; a 2026-09-11 reply says a fix is planned in an upcoming release. Replies discuss shared Bluetooth radio capacity and a 30-second photo watchdog in 0.9.0. These are issue-thread reports, not an SLA or our hardware test. Sample decoded video frames for cues instead of repeatedly requesting still photos; never require an unsupported route workaround. [Issue and replies](https://github.com/facebook/meta-wearables-dat-ios/issues/260).

## Display, controls, sleep and clearing

Display is a real native capability from SDK 0.7.0 onward. Filter devices with `supportsDisplay()`. After the parent session starts, call `addDisplay()`, retain listeners, start the capability, and wait for `DisplayState.started` before sending. Firmware/DAT-app update errors have explicit update flows. In 0.9.0 the new DAT App Model is always enabled; old `DAMEnabled` configuration is ignored.

Native UI includes `FlexBox`, `Text`, `Button`, `Image`, `Icon`, and root MP4 `VideoPlayer`, with `ButtonGroup` added in 0.9.0. Send a single root `FlexBox` for cues. Each `send()` replaces the full layout and callbacks; there is no partial update. Keep state on the phone and use the most recent button/tap callbacks for Dismiss, Pause, Stop and Analyze now. `try await display.clearDisplay()` exists since 0.8.0. Serialize send and clear so an older queued send cannot repopulate a cleared cue; invalidate generations before clearing. If disconnected, a successful local clear request cannot prove the remote screen cleared.

Users explicitly start display sessions. The app owns the display exclusively during its session; system calls/notifications may interrupt it. Captouch and Neural Band EMG gestures drive the platform controls; callbacks are abstract tap/click events, not arbitrary custom hand-gesture recognition. The root-view Back gesture ends the session. SDK reference/source: [Display guide](https://github.com/facebook/meta-wearables-dat-ios/blob/225f64ff1617e7acc8c407bb8d3ee132f7263d00/plugins/mwdat-ios/skills/display-access/SKILL.md), [DisplayViewModel](https://github.com/facebook/meta-wearables-dat-ios/blob/225f64ff1617e7acc8c407bb8d3ee132f7263d00/samples/DisplayAccess/DisplayAccess/ViewModels/DisplayViewModel.swift).

The live official documentation says the display **dims after 20 seconds and sleeps after 25 seconds of inactivity**. Display sleep does not end the DAT session; on wake, old content can remain or the phone may send fresh content. No verified mechanism guaranteeing that a new model cue wakes a sleeping display was found. Do not promise an always-on HUD or defeat sleep through artificial keep-alives. Clear expired content even when no new cue exists, test wake behavior, and distinguish phone background state from glasses display sleep.

The September 23 FAQ said Mock Device Kit did not support Display glasses. **DAT 1.0.0 supersedes that limitation with MockDisplayKit**, as documented above. A mock or app-drawn preview still does not validate physical display updates, clearing, gesture timing, ambient audio quality or locked-phone operation.

## Consent, data use, retention and access gates

Registration is an explicit Meta AI confirmation. Display camera PCM requires DAT camera/microphone permission and Camera and Audio Streaming approval, plus the app's iOS microphone permission. Regular HFP microphone access uses the phone OS permission flow. Local development requires supported glasses, compatible Meta AI/firmware, Developer Mode, and the native application's URL callback/configuration. The earlier Developer Preview publishing findings are historical; this app's current camera-audio feature remains explicitly development/beta only under the September 25 audio guide. Availability depends on supported markets. [Official FAQ](https://developers.meta.com/wearables/faq/).

The SDK license binds developers to [Wearables Developer Terms](https://wearables.developer.meta.com/terms) and [Acceptable Use Policy](https://wearables.developer.meta.com/acceptable-use-policy). Both pages returned login-only content during this research; the public docs MCP did **not** retrieve their substantive bystander/retention clauses. Their exact current requirements remain unresolved; do not claim compliance with unseen terms. The project should require affirmative consent from both demo participants, preserve hardware capture indicators, stop immediately on withdrawal, and avoid recording bystanders. These are project choices/user requirements, not invented quotations from Meta's terms.

Official repository instructions document SDK operational telemetry enabled by default, and iOS crash reporting enabled by default. `MWDAT.Analytics.OptOut = true` and `MWDAT.CrashReporting.OptOut = true` disable these respective facilities. Android uses `com.meta.wearable.mwdat.ANALYTICS_OPT_OUT`. MCP telemetry docs list identifiers, firmware, session duration, errors and success flags. Do not confuse disabling SDK analytics with controlling model-provider retention. No platform-wide media-retention duration was established. App/proxy rolling data and model-provider policy must be documented separately. [iOS privacy configuration](https://github.com/facebook/meta-wearables-dat-ios/blob/225f64ff1617e7acc8c407bb8d3ee132f7263d00/README.md).

## Hardware acceptance checks still required

| Check | Pass evidence needed |
|---|---|
| Display camera + ambient PCM + display simultaneously | Requested/received audio format, fresh timestamped frames/audio, physically visible manual cue |
| Regular camera + HFP | Actual selected glasses UID/rate, fresh frames, phone cue; no silent microphone substitution |
| Nearby voices | Wearer and partner scripted reference at multiple distances/noise levels; measure each separately |
| Continuous ambient noise | Fan/music/crowd energy does not repeatedly invalidate surroundings requests; empty ASR does not block visual etiquette |
| Library without speech | Fresh clear scene yields an appropriate qualified cue or abstention, never a claim that energy proves quiet |
| Pocket operation | Phone locked; fresh sampled frame/model request/display update; no replay of held image |
| Sleep and stale cue | Wait beyond 25 seconds, change topic, wake display; expired cue does not reappear |
| Pause/stop/dismiss | Visible clear and capture halt; delayed API responses never re-display |
| Disconnect/doff/hinges/call | Session observed, work invalidated, no restart through user stop |
| Duration/thermal | At least 10–15 minutes with timestamped metrics; no assumed three-minute timer |
| Privacy controls | No raw media saved by default, bounded transcript, explicit fallback label and consent |
