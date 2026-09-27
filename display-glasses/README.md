# Meta Display glasses

The companion uses the Display glasses camera and nearby audio to ask Muse for one brief social cue, then renders that cue through `Sources/GlassesController+Display.swift`. Open [the iOS project](../phone-app/ios/Copilot.xcodeproj) and choose **Display glasses**.

Tap **Start glasses** on the phone, then **Start** on the lens to begin capture. With conversation on, checks fire at a moment in the conversation rather than on a timer. Scene-only mode checks the scene about every **30 seconds**. The lens offers **Pause** and **Stop**. Pause offers **Resume**; Stop returns to Start while keeping controls connected. Closing the controls or stopping on the phone disconnects the session.

**Conversation and captions** is enabled by default. Streaming multi-speaker captions appear on the phone only. The glasses display one short social cue, without transcript lines or caption-driven redraws. Conversation mode retains **Analyze** on the lens; Dismiss is available on the phone. Turning off conversation mode keeps automatic scene cues.

With conversation on, a check is sent when someone else asks a question, uses a common indirect phrase, or finishes speaking and three seconds pass in silence, or when the wearer selects **Analyze**. The wearer's own turns never prompt a check. The app finds the wearer without a tap: theirs is the loudest voice at the glasses microphone, measured per caption turn. Until it is found, questions and pauses do not prompt a check. **That was me** in the phone's Settings is an optional override. Only finished turns are sent. Captions continue updating independently. In scene-only mode, Muse uses the fresh camera scene and averaged audio energy to describe the setting or suggest a considerate action.

## Capture and analysis

DAT **1.0.0** carries low-resolution **15 FPS HEVC video and 16 kHz mono ambient PCM** in one camera stream; Display uses the same `DeviceSession`. Display mode does not use an HFP microphone picker. Regular Meta glasses retain their separate HFP route and phone output.

The phone decodes frames and keeps one JPEG refreshed every **2 seconds**. Conversation audio streams to **Muse Voice Transcribe** for partial captions; six-second HTTP chunks are a fallback if the realtime connection fails. For a conversation check, **Muse Spark** receives the last three turns as text, labeled wearer or other, and no image. For a scene-only check it receives a fresh image and up to 10 seconds of averaged capture energy. No full-video upload or local glasses model is implemented.

Only one request runs at a time. A conversation cue needs a confidence of at least 0.8 and clears after **8 seconds**. There is no minimum dwell: a new cue replaces the old one at once, and an unchanged cue is not redrawn. A reply is dropped if anyone speaks before it arrives. Scene-only checks are eligible every **30 seconds**, and a scene cue stays until the next check replaces it. Dismiss waits 10 seconds before the next automatic check. Manual Analyze always answers, with "Nothing to add" when nothing fits.

Scene images must be at most **10 seconds** old at submission. An automatic conversation check needs a turn that finished within the last 15 seconds; Analyze may use the rolling 60-second transcript. Responses must arrive within **30 seconds**; the HTTP timeout is 20 seconds. Phone transcript history, profile learning, recognition and capture controls remain available.

A fresh library image can support “This looks like a library. Keep your voice low.” without any speech. Explicit words such as “I need some space” can support giving someone a moment. The app does not infer mood from faces or tone. Audio energy is uncalibrated; it does not classify sounds or prove that a room is quiet. Continuous fan/music/crowd energy does not itself invalidate a surroundings cue.

## Platform prerequisites and verification

Audio streaming is experimental and limited to development/beta use. The glasses app needs **Camera and Audio Streaming** approval in Wearables Developer Center, `.camera` and `.microphone` runtime permission, and the app's iOS microphone permission. Pair/register with Meta AI and use compatible firmware/DAT glasses-app versions. Check [native setup](../phone-app/ios/README.md) and [hardware acceptance](../docs/DEMO.md).

The [pinned 1.0.0 changelog](https://github.com/facebook/meta-wearables-dat-ios/blob/1.0.0/CHANGELOG.md) documents audio streaming and mock Display previews. The [official audio guide](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/audio-streaming/SKILL.md) and [Display guide](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/display-access/SKILL.md) were checked September 25, 2026; these guides are on `main`, because the 1.0.0 release tag omits the guide files.

The user has confirmed basic glasses streaming and scene cues. Formal audio accuracy, friend-matching accuracy, display wake, background operation and battery acceptance tests remain outstanding. The native demo is explicitly simulated and does not validate hardware or live Muse. Pause clears captured context; Stop also clears wearer notes and consent. Raw audio/video is not saved to app files. Muse credentials remain on the backend.
