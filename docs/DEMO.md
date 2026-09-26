# Consent-based demo and verification

Run the simulated demonstration first. Then run the separate hardware checklist only with a connected phone, compatible Display glasses and server-side model credentials. A working simulated cue is not evidence of successful glasses capture, speech recognition or display delivery.

## Consent and setup

Use two adult volunteers in a private setting with no uninvolved bystanders in camera or microphone range. Explain: “This prototype sends short speech recordings and occasional camera images to Meta's Standard APIs to suggest brief conversation cues. Local rolling content is cleared on pause/stop; the provider's retention rules still apply. Either of us can stop the session immediately.” Both explicitly agree before capture begins. Preserve hardware recording indicators. Stop if someone withdraws consent or an uninvolved person enters.

Do not use real confidential information, diagnoses, faces for identification, or private remembered topics. Suggested test topic: a fictional robotics project. Explain the display and Start/Pause/Stop/Dismiss controls before the phone is pocketed.

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

The native app starts in **iPhone** mode. Select **Simulated demo** explicitly to use the local scripted provider. That mode uses a synthetic camera image and typed demo lines without recording or requiring the proxy. To exercise the actual API from simulated input, disable the local scripted provider, configure the proxy and keep the input-source label visible; this still does not test glasses hardware. For real phone capture, follow the [phone acceptance sequence](REFERENCE_COMPARISON.md#phone-acceptance-sequence) first.

## Two-person hardware script

Before starting, fill in the run record: phone/OS; SDK 0.9.0; glasses model and firmware; Meta AI and DAT glasses-app versions; battery levels; selected HFP port/UID; reported buffer rate; model/provider mode; network and server build revision.

1. Pair in Meta AI, enable Developer Mode, complete app registration, grant camera and microphone permissions, and select the glasses' HFP microphone explicitly. Configure the trusted HTTPS proxy URL and separate proxy token; real hardware Start checks that the backend reports live mode before recording.
2. Enable **Connection test only (no uploads)** for the first hardware check, confirm both participants consent, then Start. Verify route settlement and fresh frame receipt. Trigger the manual display test while the session is active and verify it physically appears. Dismiss and verify it clears. Stop, turn connection testing off, configure the live proxy, re-confirm consent and Start the full session. Check a fresh phone preview/frame timestamp from the glasses before putting the phone away.
3. Put the **locked phone in a pocket**. Do not leave the screen awake and report that as background operation.
4. The partner says naturally: **“I've been working on a robotics project. We're trying to get it to sort blocks.”** Wait without demanding a cue. The wearer can ask Help if needed. A useful response might ask how it is going; abstention is better than a speculative cue.
5. After at least 30 seconds, the partner says: **“Can you have that ready by Friday?”** The referent is deliberately unclear. A useful cue requests clarification, rather than guessing what “that” means.
6. Repeat the ambiguous prompt while a request is in flight, then immediately say: **“Actually, forget Friday. Let's talk about the picnic instead.”** The outdated Friday cue must be cleared/suppressed. Observe the glasses, not only the phone log.
7. Dismiss using the glasses control; verify prompt disappearance. Pause using the glasses control and continue talking for several seconds; no new capture/cue should be produced. Resume only deliberately. Stop and verify the session ends.
8. Repeat with wearer and partner at 0.5m and 1m, in quiet and modest background noise. Compare transcript against the script separately for each speaker. HFP beamforming can suppress the partner; label that failure explicitly instead of silently moving capture to the phone.

If the glasses mic cannot capture the partner adequately, demonstrate the smallest honest alternative: explicitly selected phone/external mic with consent, if available, or labeled simulated text. Record that it does **not** satisfy glasses-only conversation capture. If an actual frame/API request cannot be made, report the blocked prerequisite rather than a fabricated successful live result.

## Failure and endurance matrix

| Test | Action | Required observation |
|---|---|---|
| Permission denial | Deny camera or microphone; Start | Clear actionable state; no silent phone-mic substitution or inference |
| Wrong/lost HFP route | Connect another headset or disconnect the selected port | Capture pauses/stops, pending work invalidates; route source remains explicit |
| Device disconnect | Fold/remove/power off glasses | Cue work invalidates; no autonomous restart after user stop; deliberate resume after availability |
| SDK pause | Trigger the documented device pause | No data processed while paused; wait for SDK resume/stop, no restart loop |
| Phone call/system interruption | Interrupt active capture | Audio stops; no late cue; deliberate continuation |
| Network failure | Disable network during ASR/cue request | Timeout/failure; no queued stale burst after recovery |
| Provider timeout/rate limit | Controlled test-provider response delayed beyond deadline or HTTP 429 | No cue; bounded active work; next eligible sample only |
| Invalid model output | Fixture missing field, invalid JSON, oversized cue, unsupported inference | Local validation rejects/abstains |
| New speech/subject | Speak before a delayed response returns | Prior result discarded, displayed cue cleared |
| Dismiss/Pause/Stop race | Use control with a request and display send pending | No stale redisplay after clear; stop halts capture |
| Display sleep | Idle at least 30s; change subject; wake normally | Report wake behavior; expired cue must not reappear; do not defeat sleep with keep-alives |
| Locked phone | Run the script with locked phone pocketed | Fresh microphone/frame/model/display activity, not retained preview |
| Stale frame | Interrupt/degrade camera decoding | Held frame is dropped or retains old timestamp; never relabeled fresh |
| Clock alignment | Compare capture/request timestamps; introduce skew in test fixtures | Implausible/future timestamps rejected; old speech/frame not used |
| Thermal and battery | **20-minute supervised hardware soak**, record every minute | Actual FPS, HFP rate/route, battery change, thermal state, pauses/errors; stop at SDK thermal/battery conditions |

The 20-minute soak is an acceptance test, not a promised runtime. Do not bypass a hardware shutdown, cover indicators or automatically reconnect through thermal errors. An SDK stream lasting beyond three minutes should be recorded as a measurement, not generalized into “unlimited.”

## Quality rubric and run record

For each candidate, the partner and wearer independently mark:

- **Useful:** concise, timely, grounded in what was actually said; helped participation.
- **False:** contradicts the spoken content, attributes an unknown speaker, invents a topic, or makes unsupported personal inference.
- **Stale:** arrived after a subject change, after dismissal/pause/stop, or when its speech evidence expired.
- **Distracting:** repeated, too frequent/long, overlaps active speech, or offers generic advice with no benefit.
- **Appropriate abstention:** uncertain, unclear, outdated or out-of-view evidence led to no cue.
- **Missed opportunity:** both people agree a specific helpful cue was warranted, but none appeared.

Log candidate/display counts and these labels without retaining raw recordings by default. Report useful, false and distracting counts alongside eligible opportunities; never call absence of cues perfect accuracy. Record median/p95 ASR time, API time and capture-to-send delay, physical display delay when observed, uploaded bytes, real returned token usage and estimated cost. Unknown values stay **unmeasured**. For mock runs use **simulated**, with no hardware/live-price claim.

Use one row per run: `date | mode | device/firmware | duration | useful | false | stale | distracting | abstentions | latency | bytes | estimated cost | limitations`. Put the completed results table in README; do not prefill this protocol with invented measurements.
