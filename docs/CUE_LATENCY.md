# Conversation cue timing

September 27, 2026: replace fixed ten-second conversation polling with a coalesced transcript-driven schedule. Final text waits 250 ms; partials wait 750 ms after the last change, capped at three seconds from the first pending change. Requests remain single-flight, at least two seconds apart (four in reduced-power mode). New words received during a request stay pending for the next snapshot. Duplicate text and speaker labels do not reset the deadline. Pause/Stop cancel pending work, and Dismiss retains its ten-second quiet interval.

Conversation cues can replace the previous cue after four seconds of reading time. Scene checks and scene-only reading time retain the existing ten-second policy. This does not change camera transport, speech synthesis, model, transcript freshness, or the guided wording/summary prompt. Faster conversation requests increase API usage compared with ten-second polling.

## Measurements and limits

The preceding phone capture log showed partial transcripts about 1–2 seconds behind captured speech. Six synthetic live requests compared the existing prompt against a shorter candidate using Muse Spark 1.3, minimal reasoning, and the same strict response schema:

| Synthetic input | Existing prompt | Shorter candidate |
| --- | ---: | ---: |
| Tennis question, text only | 3.443 s | 3.388 s |
| Social-cue question, text only | 3.303 s | 2.877 s |
| Fragmented speech with a blank test image | 2.944 s | 3.113 s |

The shorter prompt did not demonstrate a consistent material improvement, so the existing prompt remains. These are three synthetic inputs per variant, not a real-camera benchmark, quality evaluation, or end-to-end latency guarantee. Live scene complexity, network conditions and model service load can take longer. The scheduler removes avoidable app waits; it cannot guarantee a cue at the instant a sentence ends.

Meta documents `minimal` as the shortest supported reasoning setting; `none` is unsupported. [Official reasoning documentation](https://dev.meta.ai/docs/reasoning). Lowering the completion ceiling is not a speed control: it can exhaust hidden reasoning before valid JSON is returned.

`CaptionTiming` now records request start with evidence age and line count, response receipt with total request/model duration and whether newer speech is pending, and cue display with evidence age. Logs omit conversation text and generated cue content. Compare these stages during a real glasses conversation before claiming a measured end-to-end improvement.
