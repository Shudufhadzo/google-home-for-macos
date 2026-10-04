# Home Manager 0.5.5 — whole-home management and continuous shared playback

Preview release, 4 October 2026. Requires macOS 14.4 or newer; the universal app supports Apple silicon and Intel. The DMG and ZIP are signed with Developer ID and notarized by Apple. Notarization does not establish compatibility with every device.

Created by **Shudufhadzo Nemulalate**. Email: [him@shudufhadzo.com](mailto:him@shudufhadzo.com). Portfolio: [shudufhadzo.com](https://shudufhadzo.com).

## New since the published Home Speaker 0.4.2

- **Whole-home inventory:** rooms, favourites, device details, local display names, router/extender management links, and an optional Home Assistant connection for supported entity controls. Home Assistant tokens stay in macOS Keychain.
- **Unified discovery:** reconcile multiple AirPlay/UPnP advertisements from the same TV into one inventory entry, while preserving distinct Cast groups and home-hub entities.
- **Multiple outputs:** select up to eight individual Cast receivers or one Google Home speaker group, and include an AirPlay TV with **Play with AirPlay** in the same Destinations grid.
- **Continuous sessions:** Next/Previous keep capture, live streams, Cast sessions and the AirPlay item connected. The speaker no longer reconnects at every song boundary.
- **TV Now Playing:** show the current cover, title, artist and album in a video card alongside the audio, updating the picture within the existing stream.
- **Playback recovery:** bounded retries restore a briefly interrupted Cast control socket to the same media session; a short AirPlay route interruption gets a five-second grace period. Longer failures still stop the shared cast and restore local playback.
- **Stream delivery:** retain HLS fragments long enough for active clients, prevent idle sleep while casting, and support reachable IPv6 stream URLs when receiver discovery requires them.
- **Clean playback controls:** remove timing adjustment controls and setup paragraphs from the destination view; automatic alignment runs in the background.
- **Creator details:** **About Home Manager**, available from the app menu and sidebar, includes the creator credit, clickable email and portfolio, and version/build information.

## Validation and limits

The preceding playback build was checked with the real Home Speakers group and Samsung AU7000 TV. The user confirmed steady sound on both, TV artwork/title updates, and no speaker reconnection chime after Next. A separate physical test confirmed control-socket recovery without a new media load. This release adds creator details and packaging without changing that playback implementation. See [release verification](VERIFICATION-0.5.5.md) and [the playback evidence](VERIFICATION-0.5.4.md).

Automatic alignment targets a receiver-reported gap below 100 ms. Logs still show excursions above that threshold, and continuous sub-100 ms acoustic synchronisation has not been established. Cast and AirPlay have independent clocks, buffers and device processing.

The app and TV update song information in place. Google Home's own song label may retain the initial track's metadata with the default Cast receiver. The stream is audio plus a Now Playing card, not screen mirroring or arbitrary video casting.

Mixed **All Mac audio** requires macOS 26 for persistent exclusion of Home Manager's own player; **Apple Music** capture is available on earlier supported macOS versions. Protected material may not be capturable. Google Home setup and account commissioning remain in Google's supported apps; broader home controls require a configured Home Assistant server and compatible integrations. Router/extender entries provide actual management links, not universal firmware configuration.

Open the DMG and drag **Home Manager.app** to **Applications**. Quit the previous copy before opening the replacement. macOS may request Local Network, System Audio Recording and Music Automation permissions. The release assets include a ZIP alternative and SHA-256 checksums.
