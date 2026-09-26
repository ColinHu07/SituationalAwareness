# On-device FaceNet friend matching

The iPhone and glasses camera paths now share a bundled, pretrained FaceNet
InceptionResnetV1 (VGGFace2) Core ML model. Apple Vision supplies face boxes and
eye landmarks; it no longer supplies generic image feature prints for identity.
Recognition does not send photos or embeddings to a server. The existing scene
analysis path still sends sampled images when enabled, and confirmed profile
context is still available to the conversation service under its existing controls.

## Enrollment and migration

Open People, select a friend and add 3–5 clear, single-person photos with both
eyes visible, varying lighting and modest viewing angles. Group photos are rejected
instead of silently selecting the largest face. Photos need a face at least 80 pixels
on its shorter side after downscaling the source to at most 1600 pixels. Large yaw,
missing eyes and crops extending beyond the image are rejected. This is not a
complete blur, occlusion or spoof detector.

Existing names, groups and notes remain readable. Old Vision prints cannot be
converted into FaceNet embeddings; their 96-pixel thumbnails are not automatically
re-enrolled. The editor prompts for new photos, replacing legacy face samples after
the first successful new enrollment. Up to eight current samples are supported.
New photos are checked against the selected profile and other enrolled profiles;
a conflict asks the wearer to check the photo/profile.

Both paths map eye centers to (50,60) and (110,60) on a 160×160 RGB image. The
model applies `(pixel - 127.5) / 128` once, internally. Embeddings are normalized
and versioned with weights and preprocessing identity; old/incompatible or invalid
vectors never enter the gallery. Eye alignment uses Vision rather than the upstream
MTCNN crop pipeline, so upstream benchmark accuracy does not describe this app.

## Decisions

The score is unit-vector Euclidean distance, not a confidence percentage. For each
profile, average the closest two enrolled samples (one if only one exists).
A match needs distance ≤0.85 and at least 0.12 separation from the next profile.
These are provisional defaults, adjustable in Settings, not validated operating
points. Two faces claiming one profile in a frame are both rejected. Duplicate
IDs or repeated timestamps cannot count as two sightings. Existing presence rules
still need two sightings within ten seconds, or nearby spoken-name evidence.
Names and introductions can still add people separately from face matching.

Uncertain faces display “No confident friend match.” They do not acquire the nearest
person's name. New-face suggestions after introductions remain reviewable and
unsaved until accepted; ambiguous near-matches are excluded from these suggestions.
Missing/incompatible models show an error rather than falling back to Vision prints.
Gallery edits and cancelled/stale sessions invalidate in-flight recognition results.

## Reproduce the model

On macOS with Python 3.11:

```sh
python3.11 -m venv /tmp/aside-facenet
/tmp/aside-facenet/bin/pip install -r scripts/facenet/requirements.txt
/tmp/aside-facenet/bin/python scripts/facenet/export.py
```

Export downloads the upstream checkpoint into the Torch cache, converts to Core ML
float16 after checking the pinned checkpoint SHA-256, runs three synthetic image parity checks against PyTorch, and writes the
model and checksum manifest. Simulator inference uses CPU; physical devices allow Core ML to select accelerators. The ~45 MB package is included in Xcode's synchronized
Copilot group and compiled into the app; runtime requires no Python or download.
See `phone-app/ios/ThirdParty/FaceNet-NOTICE.md` for attribution.

## Acceptance with friends and the actual camera

Use permissioned enrollment photos, then separate camera recordings that were not
used for enrollment. Include multiple enrolled friends together, lookalikes,
unregistered people, different lighting, glasses, movement, partial faces and empty
frames. Record correct matches, wrong-profile matches, unknown-person false matches,
missed matches, time to confirmation, and latency/thermal behavior on the target
phone. Use separate calibration and final evaluation sets. Adjust thresholds to
reduce wrong identities; report rejection rates alongside accuracy. Do not call the
system reliable based on synthetic embeddings or upstream LFW results.

Synthetic conversion and unit tests verify packaging, numerical behavior and matching
rules. Real friend-recognition accuracy and physical glasses performance require this
held-out acceptance test; no real-world accuracy improvement is claimed yet.

## Local verification · September 26, 2026

- 98 native tests passed, including 11 FaceNet tests and real bundled-model execution
  in the iOS 26.5 simulator.
- 124 backend tests passed.
- Simulator and unsigned generic iPhone builds passed.
- Three PyTorch/Core ML conversion checks had embedding L2 errors of
  0.00765, 0.00885 and 0.00778 (limit 0.02).
- No physical-device, real-person matching accuracy or camera enrollment UI
  acceptance is claimed by these checks.
