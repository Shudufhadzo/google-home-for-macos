# Privacy

Home Speaker runs locally. It has no account system, analytics, advertising, or developer-operated backend.

- **Local Network:** discovers Cast receivers using Bonjour and sends playback commands to the selected receiver.
- **System Audio Recording:** captures either Apple Music or the Mac's audio mix, according to the selected source. Capture is sent to the receiver and is not saved to disk.
- **Automation / Music:** reads the current song, artist, album, artwork, position and playback state, and sends playback commands. It does not request Apple account credentials or upload the user's library.
- The app temporarily serves audio and available artwork over HTTP on the local network at a random, session-specific URL. The stream ends when casting stops. This is not an encrypted or authenticated audio transport; use it on a trusted local network.
- Cast control uses TLS with the receiver's local self-signed certificate. Receiver authentication is limited to the Bonjour-discovered endpoint.
- The Cast receiver and Google Home clients may display the song metadata. Their handling of that information is governed by their own services and policies.
- Basic operational diagnostics may be recorded by macOS unified logging. The app does not intentionally log audio samples, album artwork, account credentials, or track titles.

Revoke permissions in System Settings → Privacy & Security. Quitting the app destroys the capture process; stopping a cast releases the native mute tap and restores local playback.
