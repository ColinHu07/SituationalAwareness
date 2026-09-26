# Phone app

**One app, two main sources:** choose **iPhone** or **Glasses** in the same companion. Glasses with a display show the Muse cue both on the phone and through the lens. Both sources open a shared live capture screen. Follow the [live glasses test](../docs/LIVE_GLASSES_TEST.md) for pairing, the temporary HTTPS connection, and a real capture-to-cue check.

Start here: open [ios/Copilot.xcodeproj](ios/Copilot.xcodeproj) in Xcode. Select the Copilot scheme and run on an iPhone. See [setup and testing](ios/README.md).

The default **iPhone** mode uses the phone microphone and optional rear camera, with separate captions, wearer notes and AI suggestions. **Simulated demo** works without devices or credentials. The no-upload capture test checks real phone inputs before enabling Muse.

This folder owns the companion UI, phone capture, session lifecycle, API client, Xcode project and native tests. The same companion also compiles source from `../regular-glasses/Sources` and `../display-glasses/Sources`. These are three device paths within one iOS app, not three independently installed apps. Both glasses types need the phone companion.

The shared Muse proxy remains in `../server`; run `npm start` from the repository root. Its key stays in the ignored root `.env`. The browser development preview remains in `../web`.
