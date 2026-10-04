# Home Manager 0.5.4 development verification

Checked 4 October 2026 on this Apple silicon Mac. This is a local ad-hoc-signed development app, not a notarized public release.

## Changes

- Keep the audio capture, live server, AAC writers, Cast media session and AirPlay item active across Apple Music song changes. Next/Previous commands go to Music once. No STOP, LAUNCH or LOAD is issued at a song boundary.
- Render the current cover, title, artist and album into a 1280 × 720 H.264 Now Playing card for the TV. Cast retains an audio-only AAC rendition. Both writers consume the same captured PCM packets and share the same media origin.
- Update the TV picture inside the existing video timeline. Keep the initialization segment and URL unchanged; native macOS Now Playing metadata is refreshed separately through public APIs.
- Put the TV/AirPlay card in the same Destinations grid as the speakers. Show **Play with AirPlay**, the native route picker, device display name and connection state. Remove setup paragraphs, timing-offset controls, timing diagnostics and manual alignment buttons from the main playback view.
- Target receiver-reported drift below 100 ms using an 80 ms threshold, three distinct fresh reports, a four-second cooldown and damped seek feedback. Prefer adjusting Cast while the TV video/audio pipeline stays continuous. All playback remains at 1×.
- Retain 129 half-second fragments behind a 64-fragment advertised window. This fixes premature deletion of media URLs still usable by HLS clients under RFC 8216 section 6.2.2.
- Hold a macOS activity lease during casting. Allow five seconds for a temporarily interrupted AirPlay route to return.
- Recover an interrupted Cast control socket with bounded retries without loading a new media session. Reject stale socket callbacks and reconcile the receiver's actual app/content before continuing. A different media item, exhausted retries or a lasting AirPlay failure still stops the shared cast.
- Advertise a reachable IPv6 stream URL when Cast discovery returns an IPv6 endpoint or a Bonjour hostname without a resolved IPv4 address. Preserve the existing IPv4 path when an IPv4 receiver address is available.

## Automated and build evidence

- `swift test --disable-sandbox`: **98 tests, 96 passed, two opt-in physical tests skipped, zero failures**.
- Regression coverage includes fragment lifetime after removal from the playlist, bounded memory, delayed companion readiness, distinct/fresh drift samples, seek cooldown and bias, public metadata, decoded stereo AAC, and TV video containing real artwork.
- The TV round-trip test decodes a red cover, updates to a green cover in the existing stream, and verifies that the initialization data stays identical and the media clock continues past the original frames.
- `./Scripts/build-app.sh`: release build passed. Bundle version **0.5.4**, build **14**.
- `codesign --verify --deep --strict dist/HomeManager.app`: passed.
- `git diff --check`: passed.

## Physical evidence and limits

The user confirmed that the Samsung TV showed the Get Down cover/title/artist and both outputs were audible. After the continuous-session change, the user also confirmed **“No chime; TV updates”** when using Next. A natural track change and manual skips were observed without another AirPlay item preparation or live Cast load.

A later Cast control socket reset reproduced the whole-session stop. The recovery implementation was tested against the actual **Home Speakers** group on its advertised control port. The test interrupted the original NWConnection, established a replacement control socket, obtained fresh media timing, and verified the **same mediaSessionId and contentId**, with no audio reload. Playback remained Playing for the subsequent ten-second observation. This separate opt-in test passed.

The first recovery test attempts failed before reaching recovery because the IPv4 stream could not be loaded. At that time, the speaker's Bonjour hostname resolved to IPv6, its previous IPv4 address did not respond, and IPv6 ping succeeded. Changing the advertised source URL to this Mac's IPv6 address allowed the real receiver to load the stream and the recovery test to pass. This supports the IPv6 delivery fix; it does not establish a general router/DHCP diagnosis.

Receiver-reported timing reached sub-100 ms readings after alignment, but also fluctuated above that threshold and had larger excursions during startup or a network interruption. **Continuous sub-100 ms acoustic synchronisation has not been established.** No microphone measurement of physical speaker/TV output or DSP latency was made. Google Cast and AirPlay still have independent buffers and clocks.

The default Cast receiver keeps the metadata supplied at its initial LOAD. Home Manager and the TV card update every song in place. Updating the Google Home phone's title each song without reloading would require a custom receiver or another supported metadata path.

The final build was opened with Home Speakers and the Samsung selected together. Both reported Playing, with non-silent PCM capture and no repeated media load at track changes. The user confirmed **“Both play steadily; TV artwork shows.”** The user subsequently stopped the test session; that stop was recorded as a user/lifecycle action, not a network failure.

## Local evidence files

These logs are temporary local development evidence, not public release artifacts:

- `/private/tmp/home-manager-stability-tests.log`
- `/private/tmp/home-manager-stability-build.log`
- `/private/tmp/home-manager-physical-recovery.log`
- `/private/tmp/home-manager-continuous-route-loss.log`
- `/private/tmp/home-manager-continuous-settled.log`
- `/private/tmp/home-manager-final-runtime.log`

## References

- [HLS fragment lifetime requirement](https://www.rfc-editor.org/rfc/rfc8216.html#section-6.2.2)
- [Google Cast media messages and mediaSessionId](https://developers.google.com/cast/docs/media/messages)
- [AVAssetWriter metadata](https://developer.apple.com/documentation/avfoundation/avassetwriter/metadata)
- [MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter)
