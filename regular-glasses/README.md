# Regular Meta glasses

`Sources/GlassesController.swift` handles DAT registration, device selection, camera capture, microphone startup and session lifecycle. `Sources/VideoFrameDecoder.swift` decodes the glasses HEVC stream. These transport components are also reused by Display glasses so pairing and capture logic stay consistent.

Open [the companion project](../phone-app/ios/Copilot.xcodeproj), choose **Meta glasses**, and select the paired HFP microphone. The regular mode excludes Display devices and does not attach a display capability. Captions, notes and suggestions appear on the phone. Spoken suggestions are not implemented.

The display-specific rendering implementation is in `../display-glasses/Sources`. Common microphone and session code lives in `../phone-app/ios/Copilot`. No API keys belong in any of these client folders.

Hardware capture and partner speech quality remain unverified. Follow the [hardware acceptance protocol](../docs/DEMO.md). Decoder attribution is retained in the source and [Meta license](../phone-app/ios/ThirdParty/Meta-DAT-LICENSE.txt).
