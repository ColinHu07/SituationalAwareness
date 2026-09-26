# Meta Display glasses

The companion uses the Display glasses camera and nearby audio to ask Muse for one brief social cue, then renders that cue through `Sources/GlassesController+Display.swift`. Open [the iOS project](../phone-app/ios/Copilot.xcodeproj) and choose **Display glasses**.

Tap **Start analyzing** on the phone to begin an opt-in session. Camera and microphone remain active until **Pause** or **Stop**. The glasses provide **Analyze now**, **Dismiss**, **Pause**, and **Stop**; the paused screen offers **Resume analysis**. Initial Start is on the phone because it establishes the glasses session. Captions are optional under **Settings → Captions on glasses** and appear below the social cue. They are completed speech chunks, not partial streaming captions.

## Capture and analysis

DAT **1.0.0** carries low-resolution **2 FPS HEVC video and 16 kHz mono ambient PCM** in one camera stream; Display uses the same `DeviceSession`. Display mode does not use an HFP microphone picker. Regular Meta glasses retain their separate HFP route and phone output.

The phone decodes frames, keeps one JPEG refreshed every **2 seconds**, chunks audio in memory, and sends speech to **Muse Voice Transcribe**. **Muse Spark** receives a fresh image, recent recognized words, and optional coarse audio-energy metadata. The phone handles capture, scheduling and cue validation; model inference runs through the backend and Muse. No full-video upload or local glasses model is implemented.

Checks are eligible every **8 seconds** while recognized speech is less than 30 seconds old, **20 seconds** without recent recognized speech, or **30 seconds** in Low Power Mode / serious phone thermal state. Critical phone thermal state pauses analysis. A separate **30-second cue cooldown** limits automatic requests after a displayed or dismissed cue. Cues expire after **8 seconds**, without extending that cooldown. **Analyze now** bypasses automatic timing but still needs fresh evidence and an active session.

Synthetic live Muse checks took 9.51–10.09 seconds; this is not an instantaneous overlay. Only one request runs at a time. Images must be ≤10 seconds old at submission, and a scene response is discarded once its image is over 20 seconds old. Speech freshness remains 15 seconds. The HTTP timeout is 20 seconds.

A fresh library image can support “This looks like a library. Keep your voice low.” without any speech. Explicit words such as “I need some space” can support giving someone a moment. The app does not infer mood from faces or tone. Audio energy is uncalibrated; it does not classify sounds or prove that a room is quiet. Continuous fan/music/crowd energy does not itself invalidate a surroundings cue.

## Platform prerequisites and verification

Audio streaming is experimental and limited to development/beta use. The glasses app needs **Camera and Audio Streaming** approval in Wearables Developer Center, `.camera` and `.microphone` runtime permission, and the app's iOS microphone permission. Pair/register with Meta AI and use compatible firmware/DAT glasses-app versions. Check [native setup](../phone-app/ios/README.md) and [hardware acceptance](../docs/DEMO.md).

The [pinned 1.0.0 changelog](https://github.com/facebook/meta-wearables-dat-ios/blob/1.0.0/CHANGELOG.md) documents audio streaming and mock Display previews. The [official audio guide](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/audio-streaming/SKILL.md) and [Display guide](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/display-access/SKILL.md) were checked September 25, 2026; these guides are on `main`, because the 1.0.0 release tag omits the guide files.

Physical audio quality, display readability/wake, background operation and battery use remain **unverified**. The native demo is explicitly simulated and does not validate hardware or live Muse. Pause clears captured context; Stop also clears wearer notes and consent. Raw audio/video is not saved to app files. Muse credentials remain on the backend.
