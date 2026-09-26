# Captions with social cues

Research checked **September 26, 2026** against official Meta documentation, the public documentation MCP, and the downloadable iOS DAT 1.0.0 package. Physical glasses behavior has not been verified by this research.

## Finding

We can render our own captions and a social cue together in one native app's display layout. Each `display.send()` replaces the entire layout, so both must be composed into the same root view. No supported public API was found for reading the consumer Live Captions transcript or overlaying our app on its screen. This is a finding about the inspected public interfaces, not proof that no private integration exists. [Official Display guide](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/display-access/SKILL.md).

The live DAT documentation says an active app session has exclusive display control; system calls, notifications, and priority events can interrupt it. Two independent caption/cue apps should therefore not be assumed to share the glasses display. This passage was retrieved through the official MCP; query provenance is recorded below.

## Three distinct caption paths

| Path | What is established | Implication for this prototype |
| --- | --- | --- |
| Consumer **Live Captions** | Meta Ray-Ban Display provides real-time speech captions, started from the glasses, Meta AI app, or voice. Ray-Ban recommends facing the speaker. | Useful as the built-in product experience, but no public transcript subscription or supported third-party overlay integration was found. |
| DAT **`MWDATSpeech`** | On-glasses recognition supplies partial and final `TranscriptionResult` text and confidence. Requires microphone permission and capability enablement. | Could provide app-owned text without our cloud ASR. It has not been demonstrated to caption a conversation partner as reliably as consumer Live Captions. |
| DAT **camera PCM + our ASR** | Camera streaming can deliver audio alongside video; this path retains ambient voices rather than HFP's wearer-focused beamforming. | Matches this app's need to hear nearby speech. We transcribe the audio ourselves and render the result with a separate social cue. Accuracy and delay require hardware testing. |

Sources: [consumer captions instructions](https://www.ray-ban.com/usa/c/frequently-asked-questions-meta-ray-ban-display), [Speech guide](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/speech/SKILL.md), [microphone guide](https://wearables.developer.meta.com/docs/develop/dat/microphones-and-speakers/), [audio-streaming guide](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/audio-streaming/SKILL.md).

## SDK details and limits

- DAT 1.0.0 adds experimental `MWDATSpeech` and camera audio streaming. The actual tagged package includes the Speech binary product, and its public Swift interface exposes `DeviceSession.addSpeech()`, transcription/state/locale/error publishers, and `start()`/`stop()`. These are downloadable APIs, not only marketing claims. [Changelog](https://github.com/facebook/meta-wearables-dat-ios/blob/1.0.0/CHANGELOG.md), [package manifest](https://github.com/facebook/meta-wearables-dat-ios/blob/1.0.0/Package.swift), [shipped Speech interface](https://github.com/facebook/meta-wearables-dat-ios/blob/1.0.0/MWDATSpeech.xcframework/ios-arm64/MWDATSpeech.framework/Modules/MWDATSpeech.swiftmodule/arm64-apple-ios.swiftinterface).
- Speech delivers `text`, `isFinal`, and `confidence`; `-1` means confidence is unavailable. Replace the current partial, then commit a final once. The live guide describes wearer speech; it does not establish ambient-speaker performance or that this is the consumer Live Captions recognizer. The capability can stop after inactivity, timeout, or performance constraints, so continuous operation must observe state and errors. [Speech guide](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/speech/SKILL.md), [Speech API reference](https://wearables.developer.meta.com/docs/reference/ios_swift/dat/latest/mwdatspeech_speech); lifecycle details retrieved via MCP below.
- Camera PCM supports 16,000, 44,100, and 48,000 Hz with a configured channel count and presentation timestamps. The app must have Camera and Audio Streaming approval plus DAT camera/microphone permissions. The current app requests 16 kHz mono. HFP, used by regular-glasses mode, suppresses ambient voices and is not an equivalent partner-captioning input. [Audio guide](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/audio-streaming/SKILL.md), [microphone guide](https://wearables.developer.meta.com/docs/develop/dat/microphones-and-speakers/).
- Both Speech and camera audio streaming remain experimental and limited to development/beta release channels; the guides prohibit production-channel publishing for these features. A stable core SDK does not remove those feature restrictions. [Speech availability](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/speech/SKILL.md), [audio availability](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/audio-streaming/SKILL.md).
- The 1.0.0 changelog dates the release **September 24, 2026**, while the current FAQ says rollout begins **September 30, 2026**. The package can be inspected now; compatible firmware, Meta AI app, permissions and account access must be verified on the target device. The FAQ's statement that display mocks are unavailable also conflicts with the 1.0.0 changelog's `MockDisplayKit` addition. Use the tagged API for build decisions and actual device checks for availability. [Changelog](https://github.com/facebook/meta-wearables-dat-ios/blob/1.0.0/CHANGELOG.md), [FAQ](https://developers.meta.com/wearables/faq/).

## Native app versus standalone web app

Meta supports third-party native iOS/Android DAT apps with camera, audio and display capabilities. It also supports standalone HTML/CSS/JavaScript Web Apps on Display glasses. The current Web Apps FAQ lists position, location, wrist motion, dictation, handwriting and keyboard input; it does not establish ambient microphone capture, consumer caption access, or continuous conversation ASR for Web Apps. Dictation text entry is not evidence of an ambient caption feed. The native companion is the documented route for this prototype's camera/audio processing. [DAT overview](https://developers.meta.com/wearables/device-access-toolkit/), [FAQ](https://developers.meta.com/wearables/faq/).

## Current app behavior

After the full William merge, Display glasses default to scene-only analysis. Enable **Conversation and captions** to use the caption path described here. Friend profiles and matching are separate features; this research did not validate their accuracy.

With captions enabled, the glasses layout keeps the caption excerpt in body text and a separately labeled social cue in smaller `.meta` text. Both are part of one display update. New speech updates captions without cancelling pending cues. Pause, Stop and Dismiss clear cues; delivery freshness checks still reject expired results.

These are **completed transcription chunks**, not word-by-word streaming captions. Audio chunks can span up to six seconds before ASR request latency. Chunks arriving while a transcription request is in flight are dropped, so the app does not yet promise a complete conversation transcript. Caption excerpts expire after 15 seconds; the lens shows up to 60 characters and the phone up to 240. The display is an excerpt, not an archival transcript. These limits describe app logic, not Meta's consumer caption feature or a measured latency/accuracy guarantee.

## Official MCP provenance

Endpoint: [https://mcp.developer.meta.com/wearables](https://mcp.developer.meta.com/wearables). Public, unauthenticated JSON-RPC `tools/call` using `search_dat_docs`, checked September 26, 2026. The server returned documentation sections without their originating webpage URLs; these queries make the key findings reproducible:

| Query | Relevant returned section |
| --- | --- |
| `display access sessions exclusive display control` | **Sessions:** user-initiated sessions, exclusive app display control, explicit termination and system interruptions. |
| `speech recognition language continuous recognition auto stop duration` | **Overview**, **Capability lifecycle**, **Error handling:** partial/final behavior, wearer-oriented wording, normal stops on inactivity/timeout/performance constraints. |
| `Audio Streaming PCM ambient glasses microphones` | **Overview**, **Capture audio while streaming from the camera:** HFP wearer beamforming versus ambient camera-stream audio; PCM formats and beta restriction. |
| `Live captions transcription public API` | No consumer Live Captions access API was returned. Semantic-search absence is not an exhaustive proof of nonexistence. |

Some direct Wearables documentation URLs returned a login page during this check. The official GitHub guides, tagged package, and public MCP supplied the substantive SDK evidence.

## Hardware acceptance steps

1. Install the build on the paired phone; record glasses model, firmware, Meta AI version and DAT 1.0.0 compatibility. Confirm registration, capability approval and permissions; verify actual audio frames arrive.
2. With two consenting participants, read a known script at normal conversation distance. Measure wearer and partner accuracy separately, including quiet surroundings, background noise, overlap and a pause mid-sentence. Confirm the input is camera PCM, not an unintended HFP or phone route.
3. Enable captions, obtain a cue grounded in the current conversation, and physically confirm both remain legible on the lens. Check that caption refresh does not erase a still-valid cue; verify pending results still respect the app’s delivery freshness limits. Test caption toggle, cue dismissal, Pause and Stop.
4. Measure speech-to-visible-text latency and missing chunks during long speech or slow ASR. Check the 60-character excerpt, 15-second expiry, speaker changes and reconnection; no old caption should reappear after stopping.
5. Test glasses display sleep/wake, phone lock/backgrounding, calls, doffing and hinge closure. Run an initial 10–15 minute session and record thermal/battery behavior. Simulator or mock success does not establish these results.
6. Evaluate `MWDATSpeech` separately if pursuing lower-latency on-device captions: compare partner versus wearer recognition, partial updates, language availability, silent-stop recovery, and coexistence with camera/display on the actual glasses before replacing the ambient-PCM path.
