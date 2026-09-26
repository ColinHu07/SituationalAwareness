# Live glasses test in the phone app

There is one iOS application: `phone-app/ios/Copilot.xcodeproj`, scheme **Copilot**, bundle **com.colinhu07.situationalawareness**. This bundle matches the app already installed on the test iPhone. The phone and both glasses source folders compile into that target.

The main screen has **iPhone** and **Glasses** sources. Choose **Glasses → With display** for live glasses video and ambient audio, with the same social cue shown on the phone and sent to the glasses. **Without display** uses regular glasses and phone text. The scripted demo is under **Settings → Use simulated demo**.

## Connect the backend

The proxy is the Node server in this repository. It holds the Muse API key and forwards the app's analysis requests. The iPhone needs a reachable HTTPS address; `127.0.0.1` on the phone refers to the phone itself.

1. Configure the ignored `.env` with live Muse and a separate `COPILOT_PROXY_TOKEN`, then run `npm start` on the Mac. Keep model credentials out of the app and Git.
2. For an approved temporary development connection, run:

   ```sh
   cloudflared tunnel --url http://127.0.0.1:8787
   ```

3. Cloudflare prints a generated HTTPS address. Keep this terminal and the backend running. The address changes when a new quick tunnel is created. [Official quick-tunnel instructions](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/).
4. In app **Settings**, save that address and the separate proxy bearer token, then **Check proxy**. Expect **live**. The health endpoint is public; analysis and transcription require authentication.

For this development build, the installer can supply `ASIDE_PROXY_URL` and `ASIDE_PROXY_TOKEN` through the debug launch environment. The app validates the address and saves the token in Keychain. No credential is embedded in the app, project, or URL. `ASIDE_CAPTURE_MODE=display_glasses` selects the setup screen; it does not start recording. These launch conveniences are disabled in Release builds.

## Test the real inputs and outputs

1. Pair the Display glasses with this iPhone in Meta AI, enable developer mode, and ensure Camera and Audio Streaming access is available for the app. Ambient PCM is a DAT 1.0 development/beta capability. In this app, select **Glasses → With display**. The **Glasses connection** section is directly below those source controls, above Start. Tap **Pair / register with Meta AI** and complete its registration if needed.
2. For an initial hardware check, enable **Connection test only (no uploads)**, confirm participant consent, and **Start analyzing**.
3. The same app opens **Glasses live capture**. Confirm a moving glasses-camera preview and green camera/audio activity indicators. Startup now waits for a connected, compatible device and an actually decoded video frame, not just a stream-state label. Audio status uses received samples, not the configured sample rate.
4. Tap **Send test text to glasses**. Verify the same test text on the phone and through the lens, then dismiss it. This test makes no Muse calls. Use **Stop** and return to setup; **Setup** alone pauses and leaves the test-mode toggle locked.
5. Turn connection testing off, confirm consent, and start again. Keep a recognizable setting in view. Muse can use a fresh image even when nobody speaks. Tap **Analyze now**, or allow automatic checks. Scroll below the cue card for errors and **Muse observation**, which explains the returned result, including an appropriate decision not to show a cue.
6. If Muse produces a cue, the **Phone + glasses cue** card mirrors the text sent to the lens. Physically check the lens: the app cannot confirm that the wearer saw it. Earlier synthetic API checks took roughly 10 seconds; hardware-to-display time is still to be measured.
7. Check captions by saying a short, ordinary sentence nearby. Use **Pause** and **Stop** to end capture. Interrupted or silently stalled camera/audio input pauses the session and clears pending cues; resuming is deliberate.

This is live streaming with sampled analysis, not a saved video recording. Raw video/audio files are not written. Camera and microphone stay active between checks until Pause/Stop. Keep the Mac awake and the tunnel open during this test.

## Verified in this update

- 26 native tests passed, including media freshness, silent ambient audio, stall cleanup, no-upload display testing, and safe debug configuration.
- A signed build was installed and launched on the connected iPhone 17 Pro Max using the existing app bundle.
- The user-created HTTPS tunnel reached the live backend; unauthenticated analysis was rejected.
- Physical glasses preview/audio, Muse understanding of actual surroundings, and visible lens output must be confirmed in the steps above. Installation and API reachability alone do not establish those results.
