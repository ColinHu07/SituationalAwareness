# Aside: what it can and can't do, and how feasible autism-support features are

Scope: what the current "Aside" prototype does (from the local repo, read 2026-09-26), what the Meta Ray-Ban Display hardware and platform allow, how good speech recognition and speaker labelling are in real group settings, what latency is OK, the legal and policy limits on recording, and a feature-by-feature feasibility check. Repo facts are cited to repo files (relative paths under `/Users/williamxu/Desktop/Projects/SituationalAwareness`).

---

## 1. What Aside does today (capability/limits sheet from the repo)

### Takeaway
Aside is a phone-run "one brief cue at a time" helper. It looks at one low-res photo every few seconds plus recently transcribed speech, then may show a cue of up to 14 words on the glasses. It deliberately does **not** identify faces or guess emotions/intentions. Almost everything has been tested in simulation only. Real glasses performance (hearing nearby speakers, display wake, battery, latency) is **still unmeasured**.

### Cited Findings

**Capture modes** — [README.md](../../README.md), [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md)
- **iPhone:** built-in mic plus optional rear camera. Output is on the phone. Pauses when the app goes to the background.
- **Regular Meta glasses:** low-res 15 FPS HEVC video plus the glasses mic over Bluetooth HFP (8 kHz mono). Output is on the phone only; spoken output is not built. Meta's own guide says HFP beamforming **isolates the wearer's voice and suppresses other speakers**, so capturing a partner's voice this way is doubtful ([docs/research-wearables.md](../../docs/research-wearables.md)).
- **Meta Ray-Ban Display glasses:** low-res 2 FPS HEVC plus 16 kHz mono ambient PCM in one DAT 1.0.0 camera stream. The cue, and optional captions, show on the glasses.
- **Simulated demo:** typed speech and fake images, clearly labeled.

**Sampling and schedule** — [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md)
- The phone keeps one JPEG, refreshed every 2 s (max 640 px, quality 0.6). It batches about 1–6 s of audio for ASR and skips upload when there is only silence.
- A model check can run every **8 s** if speech was recognized in the last 30 s, every **20 s** otherwise, and every **30 s** in Low Power Mode or when the phone is seriously hot. Capture pauses if the phone is critically hot.
- **30 s cooldown** between automatic cues. Each cue shows for **8 s**. Speech counts as "current" for at most 15 s; images for at most 10 s. There is a 1.5 s wait after speech before a check.
- Rolling transcript: 60 s, at most 12 entries. Only one model request and one ASR request run at a time.
- Cue rules: confidence at least 0.80, at most 14 words / 90 characters, and repeats of the last 20 cues are removed.
- **Analyze now** skips the timing rules but still needs fresh evidence. The repo calls all of these "provisional settings, not measured optimal performance" ([README.md](../../README.md)).

**ASR and model** — [docs/research-model.md](../../docs/research-model.md), [server/model.mjs](../../server/model.mjs)
- ASR is `muse-voice-transcribe-1.0` over HTTP, in ENDPOINTING mode, with short WAV chunks. It gives turn timestamps. It gives **no word timestamps, no confidence scores and no emotion detection**. The implementation sets confidence to `null`.
- A realtime WebSocket ASR also exists (partial results, PCM 16/24 kHz, sessions up to 60 min). Aside does not use it yet.
- A **DIARIZATION** mode exists and adds session-local speaker labels, but Meta says it is "less tuned for low latency". Aside does not use it. Labels are not identities.
- The cue model is `muse-spark-1.3` (Chat Completions, image plus text, strict 5-field JSON: `cue`, `reason`, `confidence`, `type` ∈ {clarify, follow_up, reminder, respond, abstain}, `should_display`). Reasoning is "minimal" for surroundings and "low" for conversation, with a 4,096-token output budget.
- Spark gets **recognized text only**, not raw audio or tone. Spark 1.3 carries a documented audio-quality warning.
- Prices: Spark input $1.25/M tokens and output $4.25/M. ASR $0.18/hour.

**Latency** — [README.md](../../README.md), [docs/research-model.md](../../docs/research-model.md)
- Synthetic live image+text cue requests took **9.51–10.09 s**. A 1 s silent clip took 1.14 s for ASR.
- These numbers check transport and output format only. They do not measure accuracy or camera-to-glasses latency.
- Cue HTTP timeout is 20 s. End to end, a cue is at least ASR time plus about 10 s of model time after the words were spoken.

**Display constraints** — [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md), [docs/research-wearables.md](../../docs/research-wearables.md)
- The layout is one root FlexBox: cue first, optional captions second (240 characters max, expire after 15 s), then Analyze now / Dismiss / Pause / Stop buttons.
- Each `send()` replaces the whole screen; partial updates are not possible.
- Per the docs, the display **dims after 20 s and sleeps after 25 s** of inactivity. Whether a new cue reliably wakes it is **unverified**.
- Captouch and Neural Band gestures arrive as abstract tap/click events. Custom gestures are not available.

**Explicit non-goals and guards** — [server/model.mjs](../../server/model.mjs), [shared/protocol.mjs](../../shared/protocol.mjs)
- The prompts forbid inferring emotions, intentions, honesty, attraction, mental states, identity, diagnoses or health from faces, voice or behavior. No face ID.
- A regex blocks cue words like "autis*", "diagnos*", "angry", "anxious", "lying" and "emotion".
- Audio energy is coarse, uncalibrated dBFS. The prompt says it is **not** dB SPL and not sound classification, and it must never be used to infer the wearer's own volume.
- No sound-event classifier.

**Privacy stance** — [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md), [docs/DEMO.md](../../docs/DEMO.md), [docs/research-model.md](../../docs/research-model.md)
- Capture starts only after consent and a tap. Nothing is saved to raw audio/video files. Content lives in bounded memory. Pause clears the rolling context; Stop also clears notes and consent.
- Muse Standard content is not used for training, but it is **not zero-retention**. A cancelled request cannot pull back data already sent.
- The demo protocol requires consent from both adults and no uninvolved bystanders.
- Meta's AUP forbids biometric ID and emotion recognition in workplace/education contexts.
- The Wearables Developer Terms/AUP were behind a login and **not reviewed**.

**Platform status and open hardware unknowns** — [README.md](../../README.md), [docs/research-wearables.md](../../docs/research-wearables.md), [docs/RESEARCH.md](../../docs/RESEARCH.md)
- Ambient camera audio is an **experimental dev/beta capability**. It needs "Camera and Audio Streaming" approval and **cannot be published to production release channels**.
- Still unverified: how well nearby speakers are transcribed from Display PCM; locked-phone/pocket operation; display wake-on-cue; battery and thermal limits (no minutes-of-battery figure exists); real capture-to-display latency; cost per conversation.
- No 3-minute stream cap was found. A community report describes an 18-min run.

### Inferences
- Aside's current loop (cues about 10+ s after speech, 30 s cooldown) suits **slow, situational cues**, such as setting etiquette or "ask what they meant." It cannot give **turn-by-turn timing help**.
- The cue schema has no speaker attribution and no memory beyond 60 s. Features like recaps, name memory and debriefs would need new state and storage. They would also need a changed privacy stance, because today nothing is kept after Stop.
- The Display-mode audio path is the only one that might hear partners. It is dev/beta only, so any partner-dependent feature cannot ship to production on today's platform terms.

### Gaps
- No measured partner-speech word error rate (WER) on Ray-Ban Display ambient PCM, no measured display latency, no battery figure.
- Muse ASR accuracy benchmarks: none published that I found.
- Muse DIARIZATION latency and accuracy: not quantified in the docs.

---

## 2. Meta Ray-Ban Display hardware and platform (specs, built-in features, DAT)

### Takeaway
The display is small (600×600 px, 20° field of view, one eye) and bright (up to 5,000 nits). The glasses last about 6 h of mixed use. Meta already ships English live captions (for the person you face), phone-call captions, and live translation in about 20 languages. Third-party apps get only basic UI pieces, simple Neural Band taps/swipes, and small tester groups.

### Cited Findings
- Display: 600×600 px, 20° field of view, 42 pixels per degree, 90 Hz (content at 30 Hz), 30–5,000 nits with UV-based auto-brightness, under 2% light leakage. Battery about 6 h mixed use, 30 h with the case. Neural Band about 18 h. $799 — [Road to VR](https://roadtovr.com/meta-ray-ban-smart-glasses-display-price-release-date-specs/)
- Live captions are English only. Meta says: "For best results, face the person who is talking." They start by menu, voice ("Hey Meta, start captions") or the app. The help page says nothing about speaker labels or saved captions — [Meta help: live captions](https://www.meta.com/help/ai-glasses/23879220601763496/)
- A reviewer saw captions appear "a split second or two" after speech. They kept up with a fast YouTube video without getting every word right. The Verge's reviewer said captions work less well in very noisy places or when the speaker is out of line of sight — [Tom's Guide review](https://www.tomsguide.com/computing/smart-glasses/meta-ray-ban-display-review); [review roundup (AOL)](https://www.aol.com/articles/meta-ray-ban-display-review-155352591.html)
- "Conversation focus" uses the glasses' mic beamforming to boost the voice of the person in front of the wearer. Meta says it should also improve captioning in noise — [HearingTracker](https://www.hearingtracker.com/news/meta-ray-ban-gen-2-conversation-focus-ai-speech-enhancement-for-hearing-loss); [Meta release notes](https://www.meta.com/help/ai-glasses/1809764829519902/)
- From March 2026: live translation expanded (14 more languages, about 20 total) and English phone-call captions — [Meta release notes](https://www.meta.com/help/ai-glasses/1809764829519902/); [iTechGuides](https://www.itechguides.com/ray-ban-meta-live-translation-expands-to-20-languages-heres-what-works/)
- Connect 2026 (Sept) added: landmark-based walking directions, cycling/transit directions, voice-driven hologram avatars for calls, and more markets. No new captioning or social features were announced — [Meta Newsroom](https://about.fb.com/news/2026/09/new-features-for-meta-ray-ban-display-navigation-hologram/); [Engadget](https://www.engadget.com/2267230/everything-announced-at-meta-connect-2026/)
- Developer platform (May 14, 2026):
  - Native iOS/Android DAT supports "text, images, lists, buttons, and video playback".
  - Web Apps use HTML/CSS/JS.
  - Accessible inputs: motion/orientation, phone GPS, Neural Band input, local storage.
  - Distribution is Developer Preview: native apps via release channels of **up to 100 testers**, web apps via password-protected URLs.
  - [Meta for Developers blog](https://developers.meta.com/blog/build-for-display-glasses/)
- There are no custom Neural Band gestures. Web Apps get directional swipes, index-pinch (enter) and middle-pinch (cancel) — [DAT v0.7 discussion](https://github.com/facebook/meta-wearables-dat-android/discussions/95); [Skarredghost](https://skarredghost.com/2025/09/19/meta-wearables-device-access-toolkit/)

### Inferences
- At about 42 pixels per degree in a 20° field of view, a cue of up to 14 words (Aside's limit) is about right for a glance. Longer recaps would need scrolling or the phone.
- Meta's own captions already cover "see what the person facing me says." A third-party captions feature adds value only if it does something Meta's doesn't, such as speaker labels, recap, or clarification.
- A feature that relies on Meta's Conversation focus or live captions cannot read their output through DAT. **I found no API that exposes Meta's caption stream to third-party apps.**
- About 6 h of battery with the display in use means continuous capture plus streaming will likely drain it faster. That is untested.

### Gaps
- No official text-capacity figure (lines or characters per screen).
- No independent caption-accuracy measurement for Ray-Ban Display captions.
- No battery figure under DAT camera+audio streaming.
- Whether third-party apps can run alongside Meta's captions: not established.

---

## 3. ASR and speaker labelling (diarization) in noisy group settings; streaming latency

### Takeaway
Group conversations recorded from a distance are still hard for speech recognition. Even the best research systems make roughly 1 word error in 5 once "who said it" errors are counted. On smart glasses, the partner's speech is recognized worse than the wearer's. Accuracy also drops as you ask for lower latency. Speaker labels are useful but error-prone, especially when the number of speakers is uncertain.

### Cited Findings
- CHiME-8 DASR (real meetings, far-field mics): the baselines scored 56.5% and 62.6% macro tcpWER; the **winner scored 19.90%**. tcpWER is a word error rate that also penalizes wrong speaker and timing. Getting the speaker count right is a major source of downstream errors — [CHiME-8 DASR paper](https://arxiv.org/pdf/2407.16447); [review, ScienceDirect](https://www.sciencedirect.com/science/article/abs/pii/S0885230825001263)
- CHiME-7/8 review (32 systems): "accurately transcribing spontaneous speech in challenging acoustic environments remains difficult, even when using computationally intensive system ensembles." Even on the AMI office-meeting dataset, the best speaker-attributed WER is still above ~20% without given speaker labels — [MERL TR2026-008](https://www.merl.com/publications/docs/TR2026-008.pdf)
- **Key finding for recaps:** in the same review, LLM meeting summaries were only weakly tied to transcript accuracy. On NOTSOFAR-1, "even systems with over 50% [tcpWER] can perform roughly on par with the most effective ones (around 11%)" — [MERL TR2026-008](https://www.merl.com/publications/docs/TR2026-008.pdf)
- CHiME-8 MMCSG (Meta Aria smart glasses, two-person talks, wearer = SELF, partner = OTHER):
  - Baseline 1, first table rows (dev set as I read the extracted table): at mean algorithmic latency 0.15 / 0.34 / 0.62 s, SELF WER was 17.9 / 15.0 / 14.3%, and OTHER WER was 24.4 / 21.4 / 20.3%.
  - The organizers confirm a lasting gap between wearer and partner accuracy, and a "noticeable correlation between system latency and performance."
  - Best submissions cut WER by a few points; for example, SEUEE was −3.0 points (self) and −4.3 points (partner) on eval.
  - [MMCSG paper](https://www.isca-archive.org/chime_2024/zmolikova24_chime.pdf); [SEUEE](https://www.researchgate.net/publication/384573959_The_SEUEE_System_for_the_CHiME-8_MMCSG_Challenge)
  - Caveat: the table was parsed from PDF text, so the row labels should be checked against the original.
- Streaming diarization on DIHARD III (hard audio: restaurants, clinics, courtrooms, overlapping speech): pyannote 19.8% DER, Speechmatics 31.3%, Deepgram 39.1%, AssemblyAI 39.2%. This is a **vendor benchmark**, and latency was not measured — [pyannote blog](https://www.pyannote.ai/blog/streaming-diarization-benchmark)
- NVIDIA Nemotron 3 Diarization (open, 100M params): 14.72% DER on the VoiceArena Diarization-Bench, up to 8 speakers, adjustable streaming latency. This is a vendor claim — [Hugging Face/NVIDIA blog](https://huggingface.co/blog/nvidia/nemotron-diarization)
- Streaming ASR latency: about 307 ms P50 reported for one commercial streaming model across production calls. Most perceived delay comes from waiting for the speaker to finish (endpointing), not from compute. This is a vendor-reported figure — [AssemblyAI](https://www.assemblyai.com/blog/streaming-speaker-diarization)
- Meta's Muse ASR: ENDPOINTING mode is tuned for prompt timing, while DIARIZATION mode is "less tuned for low latency." Partial results may be revised — [repo docs/research-model.md](../../docs/research-model.md) citing [Meta speech-to-text docs](https://dev.meta.ai/docs/speech-to-text)

### Inferences
- **Live captions with speaker labels** will have meaningful errors in groups. Expect something like 15–25%+ WER on the partner even for a wearer-plus-one-partner conversation on research glasses. Wrong speaker labels are likely when people talk over each other or when the speaker count changes.
- **"What did I miss" recaps and debriefs** are more forgiving than live captions, because LLM summaries hold up against transcript errors (NOTSOFAR-1 finding). That is the strongest evidence-based argument for summary-style features over word-exact features.
- Labels like "Speaker 1/2" can't become names without face or voice ID, which Aside avoids. A user-tagging step (the wearer taps to name "Speaker 2") is a possible non-biometric route. But it is unclear whether session-level voice clustering counts as biometric processing under Meta's AUP or state laws. **This needs legal review.**

### Gaps
- No public WER or speaker-label numbers for Muse ASR or for Ray-Ban Display mics.
- No study found of diarization accuracy for groups of 3–6 people standing, at cocktail-party noise levels, with glasses mics.

---

## 4. Latency budgets for in-conversation cues

### Takeaway
People take turns with gaps of about 0–300 ms. No cloud system can give real-time "speak now" help at that speed; Aside's loop is about 10 s. Captions stay useful up to a few seconds of delay (about 4 s is cited as acceptable; ratings drop as delay grows). So Aside suits situational and after-the-fact cues, not turn-timing cues.

### Cited Findings
- Across 10 languages, answers to questions come with modal gaps of 0–200 ms. Median gaps range from 0 to 300 ms (Japanese about 7 ms, Danish about 489 ms on average) — [Stivers et al., PNAS 2009](https://www.pnas.org/doi/10.1073/pnas.0903616106)
- Deaf and hard-of-hearing (DHH) caption users (n=216): ratings fall about 1 point per 7.5 s of delay. TV delays of 7–12 s notably hurt the experience. The ASR condition averaged about 2 s delay — [arXiv 2609.11408](https://arxiv.org/abs/2609.11408)
- Roughly 4 s delay is cited as acceptable for DHH viewers (search-summary claim; the primary source is not confirmed). Students reportedly can't take part in discussions if lag exceeds about 5 s — [ACM CHI 2024](https://dl.acm.org/doi/fullHtml/10.1145/3613904.3641988); [Toronto AR captioning study](https://www.cs.toronto.edu/~sliaqat/augmented_reality_glasses.pdf) — *treat the 4 s / 5 s figures as secondary-sourced*
- Meta's built-in captions show text "a split second or two" after speech (reviewer observation) — [Tom's Guide](https://www.tomsguide.com/computing/smart-glasses/meta-ray-ban-display-review)
- Aside today: about 9.5–10 s model time plus ASR and batching (1–6 s audio chunks), plus a 1.5 s post-speech wait. That is roughly 12–17 s from words to cue. This is an estimate combining repo settings with synthetic measurements, not a measured end-to-end figure — [README.md](../../README.md), [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md)

### Inferences
- **Latency tiers for feature design:**
  - (a) Under 300 ms: turn-taking "go now" cues. Not feasible with cloud; maybe with on-phone voice-activity detection, but not validated.
  - (b) About 1–4 s: captions and "someone asked you a question". Needs streaming ASR, not Aside's HTTP chunks.
  - (c) About 10–30 s: situational cues (setting etiquette, "ask what they meant", sensory alerts). Aside's current regime.
  - (d) Minutes to after the conversation: recap, debrief, exit suggestions.
- A **pause cue** that just shows "there's a pause now" could be driven on the phone from audio energy / VAD with no model call. But Aside's own docs say energy is uncalibrated, and HFP suppresses other voices, so reliability is unknown.

### Gaps
- No study found on acceptable latency for glanceable **social** cues (as opposed to captions), and none on autistic users specifically.

---

## 5. Legal and policy limits on recording conversations and bystander capture

### Takeaway
Eleven US states clearly require all-party consent to record, and several more are mixed. Aside streams audio to a cloud model without saving files. Whether that counts as "recording" or "interception" under these laws is unresolved and needs a lawyer. Meta relies on a capture LED and user etiquette. Bystander lawsuits and regulators are active as of Aug–Sept 2026. Meta's docs indicate the LED does not light for some AI camera uses.

### Cited Findings
- All-party consent states (2026): CA, DE, FL, IL, MD, MA, MT, NV, NH, PA, WA. CT, MI, OR and VT are mixed; for example, Oregon requires all-party consent for in-person oral talks, and Connecticut is one-party for in-person under criminal law. The other ~35 states and DC are one-party — [RecordingLaw](https://www.recordinglaw.com/party-two-party-consent-states/); [BrassTranscripts](https://brasstranscripts.com/blog/state-by-state-recording-laws-2026-guide) (secondary legal summaries)
- Meta's glasses have a white capture LED with no software off switch. Blocking it disables the camera, and a 2026 update stops recording if the LED is covered. Meta disabled capture on thousands of tampered units (under 0.1% of units sold) — [CBS News](https://www.cbsnews.com/news/meta-ai-glasses-privacy-security-fixes/); [Fortune, Jul 2026](https://fortune.com/2026/07/11/meta-ray-ban-smart-glasses-camera-led-light-privacy-safeguard-super-sensing-ai-prototype-covert-recording-concerns/)
- Per Ray-Ban FAQs, the LED **does not light** for camera-based AI features (e.g., landmark ID), because the images are "analyzed" rather than saved.
  - Aug 2026: an expanded N.D. Cal. class action over bystander capture. Sept 2026: an Illinois suit over an alleged face-recognition project.
  - Norway plans stricter rules; France's CNIL has an action plan; Oslo has banned the glasses in schools.
  - [Biometric Update, Sept 2026](https://www.biometricupdate.com/202609/metas-smart-glasses-privacy-defense-falters-when-ai-can-use-camera-without-recording-light)
- Meta's user guidance: turn glasses off in sensitive places (doctor's office, changing rooms, schools); "Stop recording if anyone expresses that they would rather you not"; "Let that capture LED light shine" — [Meta AI glasses privacy page](https://www.meta.com/gb/ai-glasses/privacy/)
- Meta Model API AUP: forbids unauthorized processing of personal information, biometric identification/re-identification, and emotion recognition in workplace/education contexts. Model API Terms: end users must be adults — [repo docs/research-model.md](../../docs/research-model.md) citing [Meta AUP](https://dev.meta.ai/legal/acceptable-use-policy), [Terms](https://dev.meta.ai/legal/terms-of-service)
- The Wearables Developer Terms/AUP (bystander clauses) were login-gated and **not reviewed** — [repo docs/research-wearables.md](../../docs/research-wearables.md)

### Inferences
- Features that run continuously in groups (captions with labels, recaps) will capture people who haven't consented. In all-party states, that is a legal risk even without saved files, and it is at odds with Aside's own demo rule of "no uninvolved bystanders."
- Wearer-only or opt-in features carry much lower legal risk: own-voice meter, pre-event briefing, post-event self-report debrief, user-typed notes.
- **The "adults only" API term matters.** Much autism-support research targets children, but Muse terms require adult end users.
- Any tie to "emotion recognition in workplace/education" is barred. Aside's no-emotion stance already avoids this. Features aimed at classrooms or workplaces must stay emotion-free.

### Gaps
- Whether transient cloud transcription without storage is "recording" under CA Penal Code 632 or similar laws: not researched. Needs counsel.
- Meta Wearables Developer Terms' exact bystander rules: unseen.
- EU/UK (GDPR) rules for audio from bystanders: not covered.

---

## 6. Feasibility of candidate autism-support features

### Takeaway
The best near-term fits are situational or slow cues (sensory/setting alerts, ambiguous-language clarification, pre-event briefings, post-conversation debriefs). They match Aside's ~10 s loop, text-only evidence and no-emotion rules. Real-time turn-taking cues and reliable "who said what" in groups are the hardest. They are limited by latency, diarization accuracy, the partner-audio path, and bystander consent.

### Cited Findings (evidence that bears on feasibility)
- Earlier smartglasses work for autism exists: Empowered Brain (Google Glass) school study, and Stanford's Superpower Glass RCT (n=71 children, +4.58 points on the Vineland socialization scale vs. control after 6 weeks).
  - Both relied on **facial emotion recognition**, which Aside excludes and Meta's AUP limits in education settings.
  - Critics questioned how strong the claims were.
  - [Superpower Glass RCT summary (NIBIB)](https://www.nibib.nih.gov/news-events/newsroom/super-tool-helps-kids-autism-improve-socialization-skills); [Empowered Brain study](https://doi.org/10.3390/bs8100085); [The Transmitter critique](https://www.thetransmitter.org/spectrum/tech-firms-superpower-glass-autism-not-super-experts-say/)
- Tolerability: 16/18 (89%) children and adults with autism could wear and use the Empowered Brain glasses; 14/16 reported no negative effects — [PMC6111791](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6111791/)
- LLM summaries hold up against transcripts with 50%+ WER on NOTSOFAR-1 meetings — [MERL TR2026-008](https://www.merl.com/publications/docs/TR2026-008.pdf)
- Meta already ships English captions (for the person you face) and translation — [Meta help](https://www.meta.com/help/ai-glasses/23879220601763496/)

### Feature-by-feature assessment (inferences from the above plus repo facts)

| Feature | Fits Aside today? | Main technical blockers | Legal/policy risk | Feasibility |
|---|---|---|---|---|
| **Live captions with speaker labels** | Partly. Captions exist, but as completed chunks, not word-by-word, with no labels | Needs realtime ASR plus DIARIZATION (Muse: "less tuned for low latency"). Partner WER about 20%+ on research glasses. Group label errors. Meta already ships plain captions | High: continuous capture of everyone present | Medium-low (unlabeled captions: medium; accurate labels in groups: low) |
| **"What did I miss" / who-said-what recap** | No. Transcript is only 60 s, nothing kept after Stop | Needs a longer buffer (minutes). Summaries hold up against ASR errors, but "who said" relies on diarization. Recap needs the phone screen or several glasses screens | High: stores other people's speech longer | Medium for "what was said" (no attribution); low for reliable "who" |
| **Name/context memory (no face ID; wearer-tagged notes)** | Partly. Wearer-authored "notes"/topics exist but are cleared on Stop | Needs persistent storage, and the wearer must pick the person (e.g., a manual tag or calendar), with no automatic recognition | Low–medium if only the wearer's own notes; high if voice or face matching is used (biometric) | High (manual recall); do not auto-match |
| **Ambiguous language / sarcasm / idiom clarification from text** | Yes. The "clarify" cue type exists ("Ask what they meant by Friday") | Text-only: Spark never hears tone, so sarcasm detection from words alone is weak and must be phrased as possible, not certain. About 10 s delay. The wearer can trigger it with Analyze now | Low–medium. Must avoid "they are being sarcastic/lying" claims (the prompt forbids inferring intentions/honesty) | Medium-high for idioms/ambiguous references; low-medium for sarcasm |
| **Turn-taking / pause cues** | No. The cloud loop is about 10 s; human gaps are 0–300 ms | Would need on-phone VAD. Uses of energy are restricted and uncalibrated in the current design. Showing a cue during conversation may distract | Medium | Low for "speak now" timing; medium for coarse "you've been talking a long time" (needs own-voice detection) |
| **Own-voice volume meter** | No. The prompt explicitly forbids inferring the wearer's volume from audioContext | Energy is uncalibrated dBFS (not dB SPL). Telling wearer from others needs the HFP wearer-focused route (regular glasses) or calibration. Could run fully on the phone | Low: the wearer's own voice, can run locally | Medium, **if** calibrated per device and done on-device. Needs hardware testing |
| **Noise / sensory-load alerts** | Partly. A scene image can support setting cues; energy is not a sound level | No sound classifier, uncalibrated energy. Relative "getting louder" trends are plausible; absolute dB is not. Could use phone mic plus calibration | Low | Medium (relative trend alerts); low (accurate dB or sound-type ID) |
| **Conversation exit suggestions** | Partly. "respond"/"follow_up" cues are text-grounded | Knowing *when* to leave needs cues the model is barred from (boredom, disinterest from faces). Offering exit *phrases* when the wearer asks is easy | Low if only triggered by the wearer | High for wearer-requested scripts; low for auto-detecting "time to leave" |
| **Post-conversation debrief / summary** | No. There is no retention after Stop | Needs a session transcript kept until debrief. Robust to ASR errors. Runs on the phone after the talk, so latency doesn't matter | Medium-high: stored transcripts of others; consent needed in all-party states | Medium-high technically; gated by consent/storage policy |
| **Pre-event briefing ("unwritten rules" of a setting)** | Not in the product, but needs no sensors | Plain LLM text generation from a user-typed event description or calendar. Can be shown on the phone or glasses beforehand | Very low: no capture | High |
| **Meeting agendas / talking points** | Partly. Wearer "topics"/notes feed the model | Show a user-written agenda on the display. The model can remind of topics when explicit speech matches | Low | High |

### Inferences
- The **features least dependent on capturing others** (briefing, agendas, wearer notes, exit scripts, own-voice meter) are the most feasible. They also avoid the dev/beta-only audio path, which cannot go to production.
- **Setting cues** (library etiquette, noise trends) already match Aside's surroundings mode and are the closest to demo-ready.
- **Clarification of ambiguous language** is Aside's existing strength. Sarcasm specifically is weak, because the model sees text without tone. Claims should be framed as "this might be a joke; you could ask" rather than asserting intent.
- **Recap and debrief** have supportive evidence (summaries hold up against ASR errors). But they conflict with Aside's current "nothing kept after Stop" rule and with bystander consent. They need an explicit, recorded-consent mode.
- **Turn-taking** is the clearest mismatch between user need and technical reality: human timing is in milliseconds, Aside's loop is about 10 s.

### Gaps
- No evidence found on whether autistic adults find glanceable text cues helpful or distracting mid-conversation. The Aside repo's "distracting cue" rubric exists but has no data.
- No autism-specific latency tolerance data.
- No accuracy data for LLM sarcasm/idiom detection from transcripts under ASR errors. I did not search this in depth.
- Ray-Ban Display battery under continuous streaming, and pocketed-phone operation, remain unmeasured.
