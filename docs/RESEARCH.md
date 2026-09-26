# Research register

Research date: **2026-09-23**. This is the original research snapshot; the current native implementation now uses the separately documented Muse realtime ASR WebSocket with HTTP WAV fallback. Current behavior and verification live in the [architecture](ARCHITECTURE.md) and root README. Documentation and source inspection are distinct from successful hardware or authenticated API verification.

Detailed primary-source findings:

- [Wearables research](research-wearables.md): exact SDK/source revisions, camera, HFP microphone, display, session/background behavior, three-minute investigation, consent/terms access limitations, and hardware checks.
- [Model API research](research-model.md): endpoints and payloads, image/video/audio limits, ASR, schema output, pricing, quotas, retention and unresolved questions.
- [Architecture](ARCHITECTURE.md): the implemented route, comparison with alternatives, bounds and privacy decisions.
- [Demo and hardware protocol](DEMO.md): reproducible simulation and separate two-person hardware validation.

## Decision and evidence

| Question | Finding and consequence |
|---|---|
| Platform/SDK | **iOS DAT 0.9.0**, minimum iOS 17.2. Current official iOS and Android repositories both have camera and display samples. This Mac has Xcode 26.6 and a registered but offline iPhone; no connected phone was available for actual glasses testing. iOS is a practical environment choice, not a comparative reliability benchmark. |
| API choice | Standard **`muse-spark-1.3`**, HTTP v1 Chat Completions with a sampled image, recent transcript and strict JSON result. Dedicated **`muse-voice-transcribe-1.0`** HTTP ASR for short actual WAV chunks. Spark 1.3 has a documented audio-quality warning; use dedicated ASR. |
| Live multimodal | Spark supports uploaded MP4 with audio. No persistent Spark live video/audio socket was established. Streaming text output is not streaming video input. A separate **realtime ASR WebSocket exists**, but is not needed for the initial HTTP-chunk implementation. |
| Glasses microphone | Current guide specifies **8 kHz mono HFP** through the phone OS; not a DAT PCM API. Add camera, configure/verify HFP, then start stream. Wearer-focused beamforming suppresses other speakers, making partner transcription a hardware acceptance requirement. |
| Pocket mode | `.hvc1` supports compressed background streaming; the app must separately maintain decoding/audio/network work. Full locked-phone camera + HFP + display operation remains unverified. |
| Display | Native `MWDATDisplay` supports complete-view updates and `clearDisplay()`. Explicit sessions, root Back, button/tap callbacks and system interruptions apply. Display dims at 20s and sleeps at 25s; guaranteed wake-on-new-cue was not verified. |
| Three-minute limit | No fixed DAT three-minute streaming cap was found in current docs/samples. This is not a promise of unlimited streaming. There is no speculative periodic session restart. |
| Model privacy | Standard content is not used for training; **this is not zero retention**. Contributor models have different, incompatible personal-data restrictions and are rejected by the implementation. SDK-specific terms/AUP were login-gated, so exact unseen clauses are not claimed as verified. |
| Mock coverage | Browser/native app simulations exercise app logic. Official FAQ says SDK Mock Device Kit does not support display glasses; simulated display does not establish physical display behavior. |

## Versions and official starting points

- DAT iOS 0.9.0, released 2026-08-03; inspected commit `225f64ff1617e7acc8c407bb8d3ee132f7263d00`: [repository/changelog](https://github.com/facebook/meta-wearables-dat-ios/blob/225f64ff1617e7acc8c407bb8d3ee132f7263d00/CHANGELOG.md).
- DAT Android 0.9.0; inspected commit `974e05c569da8be01c0c9ce8bc5bc79b73ff8540` dated 2026-09-14, including Maven Central migration: [repository](https://github.com/facebook/meta-wearables-dat-android).
- [DAT docs](https://wearables.developer.meta.com/docs/develop/dat/), [microphone guide](https://wearables.developer.meta.com/docs/develop/dat/microphones-and-speakers/), [official unauthenticated docs MCP](https://mcp.developer.meta.com/wearables), [display announcement](https://developers.meta.com/blog/build-for-display-glasses/), [FAQ](https://developers.meta.com/wearables/faq/).
- [Model catalog](https://dev.meta.ai/docs/models), [image understanding](https://dev.meta.ai/docs/image-understanding), [video/audio understanding](https://dev.meta.ai/docs/video-understanding), [ASR](https://dev.meta.ai/docs/speech-to-text), [structured output](https://dev.meta.ai/docs/structured-output), [pricing](https://dev.meta.ai/docs/pricing-rate-limits), [Terms](https://dev.meta.ai/legal/terms-of-service), [AUP](https://dev.meta.ai/legal/acceptable-use-policy).

Model documentation is live and unversioned. Endpoint version is HTTP **v1**. Account model access, quotas and any retention agreement must be checked for the actual credential. No current published end-to-end latency SLA or task-specific battery figure was established.

## Open acceptance gates

1. Install on a connected, trusted iPhone paired with the user's Display glasses; verify the correct HFP port and simultaneous camera/display.
2. Authenticate with the user's model credential on the server and send a consented actual frame and WAV, recording returned usage and latency.
3. Measure partner transcription quality, wrong/distracting cues, subject-change staleness, locked-phone operation, sleep/wake, interruptions, thermal behavior and battery.
4. Inspect the authenticated Wearables Terms/AUP before sharing beyond the consented prototype. Do not interpret OS permission as a bystander's consent.
