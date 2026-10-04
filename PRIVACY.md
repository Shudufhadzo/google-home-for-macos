# Privacy

Home Manager (formerly Home Speaker) runs on your Mac. It has no developer-operated account system, analytics, advertising, or backend. Optional integrations connect to the server/device addresses you configure.

- **Local Network:** discovers Cast receivers and other advertised services using Bonjour, sends a bounded IPv4 SSDP discovery request, fetches local UPnP descriptions, reads macOS's gateway address, and sends playback commands to the selected Cast receivers or group. It does not sweep ports or capture network traffic.
- **Home inventory:** manual management addresses, room/favourite assignments, and the home-hub address/identifier are saved in local preferences. Remove a saved device in its details. Imported entity states stay in memory and are refreshed from the configured hub.
- **Home Assistant:** a user-supplied long-lived access token is stored in the macOS login Keychain. The app reads states/services and sends explicitly targeted service calls to that server. Disconnect removes the connection and its Keychain token. It does not collect your Google, Huawei, or Xiaomi account password. Integrations configured on your hub may independently use vendor cloud services.
- Device-management, hub-setup, Google Home, and documentation links open in Safari, where the destination's own authentication and privacy policies apply. Router passwords are not saved by the native app.
- Local HTTP API traffic is unencrypted; use a trusted LAN. Remote hub connections require HTTPS with normal certificate validation. API requests do not follow HTTP redirects or use shared HTTP cookies/cache.
- **System Audio Recording:** captures either Apple Music or the Mac's audio mix, according to the selected source. One capture feeds an audio-only stream shared by the Cast destinations and, when selected, an audio/video Now Playing stream for the AirPlay TV. Media stays in memory and is not saved to disk. Receiver timing is polled during casting to monitor/align supported live playback; timing and destination selections are not persisted.
- **Automation / Music:** reads the current song, artist, album, artwork, position and playback state, and sends playback commands. It does not request Apple account credentials or upload the user's library.
- The app temporarily serves audio and available artwork over HTTP on the local network at a random, session-specific URL. The stream ends when casting stops. This is not an encrypted or authenticated audio transport; use it on a trusted local network.
- Cast control uses TLS with the receiver's local self-signed certificate. Receiver authentication is limited to the Bonjour-discovered endpoint.
- The Cast receiver and Google Home clients may display the song metadata. Their handling of that information is governed by their own services and policies.
- When joining playback started elsewhere, the Mac fetches album artwork from the HTTP(S) image URL supplied by that Cast session. The image host receives an ordinary image request.
- **Creator links:** the About window opens your mail app for the creator email or your browser for the portfolio only when you choose a link. Opening the About window itself makes no network request.
- Basic operational diagnostics may be recorded by macOS unified logging. The app does not intentionally log audio samples, album artwork, account credentials, or track titles.

Revoke permissions in System Settings → Privacy & Security. Quitting the app destroys the capture process; stopping a cast releases the native mute tap and restores local playback.
