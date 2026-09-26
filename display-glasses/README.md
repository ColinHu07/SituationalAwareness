# Meta Display glasses

The companion uses the Display glasses camera and nearby audio to ask Muse for one brief social cue, then renders that cue through `Sources/GlassesController+Display.swift`. Open [the iOS project](../phone-app/ios/Copilot.xcodeproj) and choose **Display glasses**.

Tap **Start glasses** on the phone, then **Start** on the lens to begin capture. Automatic checks run about every **10 seconds**, or **15 seconds** in reduced-power mode. The lens offers **Pause** and **Stop**. Pause offers **Resume**; Stop returns to Start while keeping controls connected. Closing the controls or stopping on the phone disconnects the session.

**Conversation and captions** is enabled by default. Streaming multi-speaker captions appear on the phone only. The glasses display one short social cue, without transcript lines or caption-driven redraws. Conversation mode retains **Analyze** on the lens; Dismiss is available on the phone. Turning off conversation mode keeps automatic scene cues.

Muse summarizes roughly the last 10 seconds and bases its cue on that summary in one request. Streaming partials are included before a sentence is finalized; corrections and finals do not refresh old words. Word timing is approximate because ASR supplies stream progress, not individual word timestamps. The phone's **Recent context** card shows the summary, while its captions continue updating independently. Without clear conversation, Muse uses the fresh camera scene and averaged audio energy to describe the setting or suggest a considerate action.

New social cues are also spoken once through the selected Bluetooth output. Captions and summaries remain silent. Choose the glasses in Control Center if the phone shows an audio-route notice. **Settings → Speak social cues** turns playback off. Transcription briefly pauses during cue playback to avoid capturing its own voice. See [audio implementation and hardware checks](../docs/CUE_AUDIO.md).

## Capture and analysis

DAT **1.0.0** carries low-resolution HEVC video and **16 kHz mono ambient PCM** in one camera stream; Display uses the same `DeviceSession`. With spoken cues enabled, video requests **2 FPS** to leave Bluetooth capacity for the HFP voice connection. Sessions started with spoken cues disabled request **15 FPS**. Display mode matches the selected glasses' voice route automatically, without an HFP microphone picker. Regular Meta glasses retain their separate HFP route and phone output.

The phone decodes frames and keeps one JPEG refreshed every **2 seconds**. Conversation audio streams to **Muse Voice Transcribe** for partial captions; six-second HTTP chunks are a fallback if the realtime connection fails. **Muse Spark** receives the recent speech window, fresh image and up to 10 seconds of averaged capture energy. No full-video upload or local glasses model is implemented.

Checks are eligible every **10 seconds**, or **15 seconds** in reduced-power mode. Only one request runs at a time. A cue stays visible for at least **10 seconds** before replacement, and an unchanged cue is not redrawn. Dismiss waits 10 seconds before the next automatic check. Manual Analyze bypasses the check cadence but retains the reading time and fresh-evidence requirements.

Images and current speech must be at most **10 seconds** old at submission. Responses must arrive within **30 seconds** and still have evidence no older than 30 seconds; the HTTP timeout is 20 seconds. Model and network latency add to the check interval. Earlier summaries remain background, not proof of an ongoing conversation. Phone transcript history, profile learning, recognition and capture controls remain available.

A fresh library image can support “This looks like a library. Keep your voice low.” without any speech. Explicit words such as “I need some space” can support giving someone a moment. The app does not infer mood from faces or tone. Audio energy is uncalibrated; it does not classify sounds or prove that a room is quiet. Continuous fan/music/crowd energy does not itself invalidate a surroundings cue.

## Platform prerequisites and verification

Audio streaming is experimental and limited to development/beta use. The glasses app needs **Camera and Audio Streaming** approval in Wearables Developer Center, `.camera` and `.microphone` runtime permission, and the app's iOS microphone permission. Pair/register with Meta AI and use compatible firmware/DAT glasses-app versions. Check [native setup](../phone-app/ios/README.md) and [hardware acceptance](../docs/DEMO.md).

The [pinned 1.0.0 changelog](https://github.com/facebook/meta-wearables-dat-ios/blob/1.0.0/CHANGELOG.md) documents audio streaming and mock Display previews. The [official audio guide](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/audio-streaming/SKILL.md) and [Display guide](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/display-access/SKILL.md) were checked September 25, 2026; these guides are on `main`, because the 1.0.0 release tag omits the guide files.

The user has confirmed basic glasses streaming and scene cues. Formal audio accuracy, friend-matching accuracy, display wake, background operation and battery acceptance tests remain outstanding. The native demo is explicitly simulated and does not validate hardware or live Muse. Pause clears captured context; Stop also clears wearer notes and consent. Raw audio/video is not saved to app files. Muse credentials remain on the backend.
