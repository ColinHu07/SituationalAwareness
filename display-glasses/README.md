# Meta Display glasses

`Sources/GlassesController+Display.swift` owns the glasses layout, caption and suggestion rendering, wearer note fallback, button callbacks, and serialized display send/clear operations.

Open [the companion project](../phone-app/ios/Copilot.xcodeproj) and choose **Display glasses**. This mode attaches camera and display to the same DAT session and uses the selected HFP microphone. Connection and camera transport are shared with `../regular-glasses/Sources`.

Captions use completed speech chunks, not word-by-word streaming. Dismiss clears the suggestion independently; Pause and Stop clear captured context. Physical display delivery, readability, wake behavior and simultaneous camera/audio operation require real-device testing. See the [hardware acceptance protocol](../docs/DEMO.md).

This is a companion-app source module, not a standalone app installed on the glasses. Muse credentials remain on the shared backend.
