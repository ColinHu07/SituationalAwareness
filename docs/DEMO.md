# Consent-based demo and verification

Run the simulated demonstration first. Then run the separate hardware checklist only with a connected phone, compatible Display glasses and server-side model credentials. A working simulated cue is not evidence of successful glasses capture, speech recognition or display delivery.

## Consent and setup

Use two adult volunteers in a private setting with no uninvolved bystanders in camera or microphone range. Explain: “This prototype sends short speech recordings and occasional camera images to Meta's Standard APIs to suggest brief social cues about the setting or conversation. Local rolling content is cleared on pause/stop; the provider's retention rules still apply. Either of us can stop the session immediately.” Both explicitly agree before capture begins. Preserve hardware recording indicators. Stop if someone withdraws consent or an uninvolved person enters.

Do not use real confidential information, diagnoses, faces for identification, or private remembered topics. Suggested test topic: a fictional robotics project. Explain Start analyzing, Analyze now, Pause, Stop and Dismiss before the phone is pocketed. Capture remains active between checks until Pause/Stop. An explicit statement about needing space is appropriate evidence; do not test guessed mood from a face or tone.

## Reproducible local simulation

1. From the project root, run `npm start` with default `MODEL_MODE=mock`, then open `http://127.0.0.1:8787`. No credential is needed for loopback mock mode.
2. Keep **Input source → Simulated conversation**. Confirm **SIMULATED DISPLAY** and **Processing → SIMULATED MODEL**. Check the participant-consent box, then **Start session**.
3. Click **A topic** (the simulated line is “I’ve been working on a robotics project.”). Wait for a natural pause. A simulated follow-up cue should mention the robotics project.
4. Click **Dismiss cue**. Confirm it disappears and the same cue is suppressed during the cooldown/deduplication interval.
5. Click **An unclear question** (“Can you have that ready by Friday?”), then **Help me respond** after the 1.5-second quiet interval, or wait for the automatic cooldown. Expected fixture: **“Ask what they meant by Friday.”**
6. Click **Change subject** (“Anyway, let’s talk about dinner instead.”). The prior cue clears; an earlier delayed Friday response must not appear after the new utterance. Run the stale-response automated test as well; ordinary fast loopback responses may finish before a manual subject change.
7. Click **Unclear speech**. Its explicitly low simulated speech confidence should cause abstention. **Pause** clears rolling context and cues and stops capture; Help produces no cue. **Stop** also clears saved session context and consent. Starting again is deliberate.

For a quick single-button pass, start a fresh consented session and click **Run scripted demo**: it inserts the Friday question, changes subject after 5.5 seconds, and reports completion after eight seconds. **Test display** exercises a manual simulated cue independently of model inference. In **Failure testing & feedback**, use **Disconnect device**, **Simulate network loss**, and **Mark distracting cue**; **Export metrics only** downloads content-free counters/timings. Escape stops the session; outside text-entry fields, Space pauses and Enter dismisses.

These two fixture cues are deliberately narrow mock logic. They do not test Muse reasoning. Simulated transcript injection is not transcription. Any webcam, phone-microphone or prerecorded-input option must identify its actual source and must not be represented as glasses input.

For the explicit development fallback, Stop, select **Browser camera + manual / mic input**, re-confirm consent and Start. **Enable browser camera** uses this computer's camera; **Record browser mic · 6 sec** sends a six-second recording through live ASR. **Manual transcript** is labeled **explicit text fallback**. Real browser input requires a live backend; the app refuses to silently return a mock model response. The display remains simulated. Browser tab hiding pauses the session, so this path is not a pocket-mode substitute.

## Native surroundings simulation

The native app starts in **iPhone** mode. Select **Simulated demo**, keep **Local scripted model (no network)** enabled, confirm consent and tap **Start analyzing**. No camera or microphone records in this mode.

1. Tap **Quiet library**. Without adding speech, expect the fixture cue **“This looks like a library. Keep your voice low.”** It uses an explicitly synthetic image, not a real library photo. The local image expires after 10 seconds; tap the scene again for fresh input if needed.
2. Dismiss, tap **Group conversation**, then **Analyze now** while the new image is fresh. Expect **“People are talking. Wait for a pause before joining in.”** Manual analysis bypasses the automatic cooldown; it does not bypass evidence freshness.
3. Tap **Someone needs space**, which inserts **“I've had a rough day. I need some space.”** After the speech pause, tap Analyze now. Expect **“They mentioned a hard day. Listen and give them space.”** This follows explicit words; it is not emotion recognition.
4. Change subject during a pending request and verify the prior cue does not appear. Pause clears capture context and disables analysis. Resume is deliberate. Stop also clears notes and consent. A normal cue expires after 8 seconds without extending the 30-second automatic cue cooldown.

These fixtures exercise the native surroundings path. They do not evaluate Muse or DAT sensors. Disable the local model and configure the live proxy to check actual image/text transport from simulated input; the synthetic source must remain visible and still does not establish scene accuracy. For real phone-only capture, use the [phone acceptance sequence](REFERENCE_COMPARISON.md#phone-acceptance-sequence).

## Two-person hardware script

Before starting, record phone/OS; **SDK 1.0.0**; glasses model/firmware; Meta AI and DAT glasses-app versions; camera-audio approval; battery levels; requested/received PCM format and timestamps; model mode; network and server build revision. For the separate regular-glasses route, also record selected HFP port/UID and reported buffer rate.

1. Pair/register through Meta AI, configure Developer Mode as appropriate, and grant camera/microphone permissions. **Display glasses** requires **Camera and Audio Streaming** app approval and compatible development/beta access. Select Display glasses; there is no HFP picker for this route. Grant the app's iOS microphone permission when requested. See the [official audio guide](https://github.com/facebook/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/audio-streaming/SKILL.md), checked September 25, and [pinned release notes](https://github.com/facebook/meta-wearables-dat-ios/blob/1.0.0/CHANGELOG.md).
2. Enable **Connection test only (no uploads)**, confirm consent, then **Start analyzing**. Verify fresh frames and received ambient audio; requested transport is low-resolution 2 FPS HEVC plus 16 kHz mono PCM. Trigger **Manual glasses display test**, physically verify appearance, Dismiss and verify clearing. Stop. No ASR or model request should be sent during this check.
3. Turn connection testing off, configure a trusted HTTPS proxy and separate proxy token, and Check proxy. It must report live mode before real capture. Reconfirm consent and Start. Verify fresh glass-camera timestamps before pocketing the phone.
4. In a consented library-like test area with clear bookshelves/signage, remain silent. Check that fresh visual context alone can produce a qualified volume/etiquette cue or an appropriate abstention. A missing transcript must not prevent a check. Do not treat low audio energy as evidence of quiet or expect a fixture phrase verbatim from Muse.
5. Have the partner speak naturally at **0.5 m**, then **1 m**: **“I've been working on a robotics project. We're trying to get it to sort blocks.”** Compare recognized text for the partner and wearer separately. Repeat with a small consenting group. Ambient PCM is not proof of intelligible partner capture until measured.
6. Before a new run, create one unique saved profile named **Sam**. Have that partner say **“I'm Sam.”** after realtime captions are connected. Verify the visible row changes from its raw `P` label to **Sam** while timing diagnostics still show the raw label. Have the wearer produce a separate finalized line, tap **That was me**, and verify only that label displays **You**. Stop and restart; neither name may reappear until new evidence is established. Repeat with two known people present and verify mere presence does not assign either name. Record actual label stability and any reconnect reassignment; simulator tests do not establish these provider/hardware behaviors.
7. After at least 30 seconds, say **“Can you have that ready by Friday?”** A useful cue asks for clarification. Then say **“I've had a rough day. I need some space.”** A useful cue acknowledges those explicit words or suggests giving space, without claiming to read facial emotion or tone. Use **Analyze now** after ASR completes when a manual check is needed.
8. Test **continuous ambient noise** with a fan or consenting non-confidential background audio. Keep the scene visible and allow repeated ASR chunks. Record whether energy-only activity or empty ASR prevents surroundings checks; it must not continually invalidate them. Then add clear speech and verify recognized words update the conversation. Record ASR errors, dropped chunks and whether noise is misrecognized as words.
9. Start a request after the Friday prompt, then immediately say **“Actually, forget Friday. Let's talk about the picnic instead.”** Once new speech is recognized, the old result must be suppressed/cleared. Observe the glasses, not only phone state. This path invalidates on recognized words, not every ambient energy buffer.
10. Use glasses **Dismiss**, **Pause**, **Resume analysis**, and **Stop**. While paused, continue speaking for several seconds and verify no capture/inference continues. Resume must be deliberate and create fresh inputs. Enable **Captions on glasses** in Settings and verify captions are readable below the social cue.
11. Put the **locked phone in a pocket** and repeat visual, nearby-speech and control checks. An awake phone is not a background test. Observe display sleep/wake without artificial keep-alives. Follow the 20-minute supervised soak below; this is an acceptance test, not a promised runtime.
12. Separately test **Meta glasses** mode to confirm regular-glasses behavior is preserved: select its HFP UID explicitly, verify the two-second route settlement and camera start, and check phone output. Repeat partner/wearer transcription in quiet and noise. Record HFP suppression independently from the Display PCM results.

If nearby speech cannot be captured adequately, record the failure and demonstrate only an explicitly selected, consented alternative such as phone input or labeled simulated text. Do not silently substitute a microphone or claim glasses-only success. If approval, firmware, hardware or model credentials block a live run, report that prerequisite and leave measurements unverified.

## Failure and endurance matrix

| Test | Action | Required observation |
|---|---|---|
| Permission denial | Deny camera or microphone; Start | Clear actionable state; no silent phone-mic substitution or inference |
| Display PCM permission/error | Deny DAT microphone permission, omit app approval, or induce stream audio failure | Start fails or capture pauses; no HFP/phone fallback or fabricated audio |
| Wrong/lost HFP route (regular glasses) | Connect another headset or disconnect the selected port | Capture pauses/stops, pending work invalidates; route source remains explicit |
| Device disconnect | Fold/remove/power off glasses | Cue work invalidates; no autonomous restart after user stop; deliberate resume after availability |
| SDK pause | Trigger the documented device pause | No data processed while paused; wait for SDK resume/stop, no restart loop |
| Phone call/system interruption | Interrupt active capture | Audio stops; no late cue; deliberate continuation |
| Network failure | Disable network during ASR/cue request | Timeout/failure; no queued stale burst after recovery |
| Provider timeout/rate limit | Controlled test-provider response delayed beyond deadline or HTTP 429 | No cue; bounded active work; next eligible sample only |
| Invalid model output | Fixture missing field, invalid JSON, oversized cue, unsupported inference | Local validation rejects/abstains |
| New recognized speech/subject | New transcript arrives before a delayed response returns | Prior result discarded, displayed cue cleared |
| Ambient noise without words | Run steady fan/music through several chunks with a fresh scene | Energy-only activity does not starve surroundings checks; no sound/mood/quiet claim from energy |
| Scene without speech | Show a clear consented library-like setting | Fresh-image analysis remains eligible; unsupported scene detail leads to abstention |
| Adaptive cadence | Compare no recent words, recognized words, Low Power Mode and serious thermal state | Eligible cadence 20s / 8s / 30s, subject to separate cue cooldown and fresh-input gates |
| Dismiss/Pause/Stop race | Use control with a request and display send pending | No stale redisplay after clear; stop halts capture |
| Display sleep | Idle at least 30s; change subject; wake normally | Report wake behavior; expired cue must not reappear; do not defeat sleep with keep-alives |
| Locked phone | Run the script with locked phone pocketed | Fresh microphone/frame/model/display activity, not retained preview |
| Stale frame | Interrupt/degrade camera decoding | Held frame is dropped or retains old timestamp; never relabeled fresh |
| Clock alignment | Compare capture/request timestamps; introduce skew in test fixtures | Implausible/future timestamps rejected; old speech/frame not used |
| Thermal and battery | **20-minute supervised hardware soak**, record every minute | Actual FPS, PCM format/timestamps (HFP rate/route for regular mode), battery change, thermal state, pauses/errors; phone critical thermal state pauses, SDK errors are respected |

The 20-minute soak is an acceptance test, not a promised runtime. Do not bypass a hardware shutdown, cover indicators or automatically reconnect through thermal errors. An SDK stream lasting beyond three minutes should be recorded as a measurement, not generalized into “unlimited.”

## Quality rubric and run record

For each candidate, the partner and wearer independently mark:

- **Useful:** concise, timely, grounded in current visible context or explicit words; helped participation or etiquette.
- **False:** contradicts the scene/words, attributes an unknown speaker, invents a topic, treats energy as a sound/quietness label, or makes unsupported personal inference.
- **Stale:** arrived after a subject change, after dismissal/pause/stop, or when its image/speech evidence expired.
- **Distracting:** repeated, too frequent/long, overlaps active speech, or offers generic advice with no benefit.
- **Appropriate abstention:** uncertain, unclear, outdated or out-of-view evidence led to no cue.
- **Missed opportunity:** both people agree a specific helpful cue was warranted, but none appeared.

Log candidate/display counts and these labels without retaining raw recordings by default. Report useful, false and distracting counts alongside eligible opportunities; never call absence of cues perfect accuracy. Record median/p95 ASR time, API time and capture-to-send delay, physical display delay when observed, uploaded bytes, real returned token usage and estimated cost. Unknown values stay **unmeasured**. For mock runs use **simulated**, with no hardware/live-price claim.

Use one row per run: `date | mode | device/firmware | duration | useful | false | stale | distracting | abstentions | latency | bytes | estimated cost | limitations`. Put the completed results table in README; do not prefill this protocol with invented measurements.
