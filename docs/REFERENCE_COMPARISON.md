# Read the Room review and Muse adaptation

Reviewed **2026-09-25** at upstream commit **37905d5447ec4046190aaf8d9d6ba35a8f760495**: [max-lee-dev/sbu-hacks-read-the-room](https://github.com/max-lee-dev/sbu-hacks-read-the-room/tree/37905d5447ec4046190aaf8d9d6ba35a8f760495). Source was inspected in a temporary checkout, not merged into this workspace. The checked-out root had no LICENSE file; this implementation retains our own code and treats the repository as a functional reference.

## What the reference actually does

| Component | Observed implementation | Consequence |
|---|---|---|
| Phone UI | Next.js/React browser application | A phone-friendly website, not a native glasses companion |
| Capture | Browser `getUserMedia` camera+audio; `Recorder.tsx` configures 1 sampled frame/sec and **3,000 ms maximum recording** | A short clip followed by analysis; not a continuous conversation assistant |
| Primary inference | `/api/analyze` sends image frames and a noise-level label to **Gemini 2.5 Flash**, then calls Gemini again to summarize | Two inference passes; the request does not send the audio recording for speech recognition |
| “transcription” | Summarization prompt defines this field as generated scene narration | **Not actual speech transcription or captions**, despite its name |
| Spoken output | `/api/audio` uses **ElevenLabs** text-to-speech | Reads generated text aloud; it does not transcribe audio |
| Extra guidance | `/api/maistro` proxies **NeuralSeek mAIstro** using scene setting | A separate optional provider, not part of Gemini |
| Storage | Records video and thumbnails to Supabase and calls `getPublicUrl`; analysis is saved in browser storage | Different retention/sharing behavior from our memory-only conversation design; actual accessibility depends on bucket policy |

Code evidence: [Recorder](https://github.com/max-lee-dev/sbu-hacks-read-the-room/blob/37905d5447ec4046190aaf8d9d6ba35a8f760495/app/components/Recorder.tsx), [analysis client](https://github.com/max-lee-dev/sbu-hacks-read-the-room/blob/37905d5447ec4046190aaf8d9d6ba35a8f760495/app/lib/analysis/SocialAnalysisClient.ts), [Gemini route](https://github.com/max-lee-dev/sbu-hacks-read-the-room/blob/37905d5447ec4046190aaf8d9d6ba35a8f760495/app/api/analyze/route.ts), [summary prompt](https://github.com/max-lee-dev/sbu-hacks-read-the-room/blob/37905d5447ec4046190aaf8d9d6ba35a8f760495/app/prompts/summarize_prompt.ts), [audio route](https://github.com/max-lee-dev/sbu-hacks-read-the-room/blob/37905d5447ec4046190aaf8d9d6ba35a8f760495/app/api/audio/route.ts), [mAIstro route](https://github.com/max-lee-dev/sbu-hacks-read-the-room/blob/37905d5447ec4046190aaf8d9d6ba35a8f760495/app/api/maistro/route.ts), [video storage](https://github.com/max-lee-dev/sbu-hacks-read-the-room/blob/37905d5447ec4046190aaf8d9d6ba35a8f760495/app/lib/videos.ts).

## Meta replacement: more than an API-key swap

Our proxy already uses Standard **Muse Spark 1.3** for image+transcript reasoning with strict structured output. Genuine captions use **Muse Voice Transcribe 1.0**, a separate Meta model/API accessed with the server-side credential. Its account availability still needs an authenticated test. No Gemini, NeuralSeek, ElevenLabs or Supabase account is needed by this prototype.

The current native caption path sends normalized mono PCM16 to the backend realtime relay, which requests Muse Voice `DIARIZATION` and cumulative partials. Partials immediately replace the live hypothesis; finalized turns receive session-local `P1`/`P2` aliases. The bounded WAV HTTP endpoint remains automatic fallback when realtime is unavailable. This is app-owned ASR, not the consumer Live Captions feed. A text-to-speech replacement is not bundled into Spark reasoning; regular glasses currently show results on the companion phone, without spoken suggestions.

Sources rechecked: [Meta model catalog](https://dev.meta.ai/docs/models), [speech to text](https://dev.meta.ai/docs/speech-to-text), [realtime ASR](https://dev.meta.ai/docs/api-reference/voice/realtime), [video/audio understanding](https://dev.meta.ai/docs/video-understanding). No live request was made: the key was absent locally.

We preserve the useful concept of contextual assistance, but do not port the reference's judgments about whom to approach/avoid from appearance, its generated narration under a transcription label, or automatic video uploads. Caption text comes from ASR, user notes come from the wearer, and model suggestions are explicitly labeled.

## Three modes, phone first

| Mode | Capture | Output | Implementation/test status |
|---|---|---|---|
| **iPhone** (default) | Explicit built-in microphone; optional rear camera via AVFoundation | Captions, session notes, occasional Muse suggestions on phone | Implemented; source/build/state tests available. Real microphone/camera/API testing still needs a connected iPhone and credential. |
| **Meta glasses** | DAT camera plus explicitly selected HFP mic; selector excludes Display devices | Captions/notes/suggestions on phone; no audio narration yet | Implemented capture branch; hardware unverified. No attempt to add a nonexistent display. |
| **Display glasses** | DAT camera+display in one session, selected HFP mic | Phone plus glasses caption/suggestion layout; first saved note shown when no suggestion | Compiled path; physical layout/update rate, sleep and microphone quality remain unverified. |
| **Simulated demo** | Typed fixture and synthetic camera image | Simulated phone captions and suggestions | Test mode only, no recording. Clearly labeled. |

The phone mode does not initialize Meta DAT and does not require glasses pairing. This separates phone acceptance from wearable SDK setup. Switching capture modes requires Stop. Phone mode pauses when the app backgrounds; it is not advertised as a locked-phone camera mode. The backend may later run on a trusted HTTPS host without changing these capture modes.

## Phone acceptance sequence

1. Build/install `phone-app/ios/Copilot.xcodeproj`. Choose **iPhone**, turn **Capture test only (no uploads)** on for the first check, confirm participant consent, Start.
2. Verify microphone permission and displayed source rate. With camera enabled, verify rear-camera permission and fresh preview. Stop and verify capture ends. No API key is required for this step.
3. Configure `.env` on the server for live Muse and a separate proxy token. Configure a reachable trusted HTTPS URL in iPhone Settings. Stop and disable Capture test only. Confirm consent and Start again.
4. Say “Would you like that hot or iced?” The exact ASR result should appear under **Captions**, separate from a wearer-entered **Your notes** entry such as “Small iced latte.” A model suggestion may abstain; do not demand a redundant cue.
5. Continue speaking while a prior request runs. Captions retain their own age/order checks, while suggestions from obsolete context are discarded. Dismiss a suggestion: captions and notes must remain. Pause clears captured content, and Stop also clears saved notes.
6. Deny permissions, interrupt audio, lose network, background the app, and resume deliberately. Record actual caption delay, errors and usefulness. Simulator tests do not replace this sequence.

No real iPhone, glasses or authenticated Muse test was available on 2026-09-25. See README for executed build/test results; do not interpret implemented paths as completed hardware validation.
