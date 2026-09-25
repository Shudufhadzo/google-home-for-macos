# Home Speaker 0.3.0

First public source release of the independent Google Home for macOS project.

## Included

- Native SwiftUI app with local Google Cast speaker discovery and playback/volume controls.
- Apple Music or full Mac audio capture, native automatic local muting, and restoration when casting stops.
- Uncompressed stereo PCM with corrected channel indexing and bounded delivery.
- Song title, artist, album, and artwork in Home Speaker and the Cast receiver.
- A fresh receiver stream for track changes: the old stream is stopped, old queued audio is discarded, and the new song is held until the receiver connects. Song metadata loads with the new media identity rather than only changing the existing queue item.
- Universal Intel and Apple silicon app packaging; MIT license, privacy/attribution documentation, and GitHub Actions tests.

## Verification and limits

Ten automated tests pass locally, including waveform integrity over HTTP, separate artwork retrieval, track identities, capture cancellation, and audio cutover. A physical L09G session completed a Next transition and resumed the new song; listening and phone display feedback are separate checks. The prior audio-fidelity build was confirmed clear with local Mac playback muted.

Cast still introduces buffering; this release does not claim zero latency or video synchronization. Only the Xiaomi Mi Smart Speaker L09G has been physically exercised. Apple Music capture can be limited by protected content. Initial speaker setup still requires Google's phone app.

## Binary status

The attached DMG and ZIP are **ad-hoc signed development packages, not Apple-notarized public installers**. They are held in a draft release pending Developer ID signing, notarization, and final listening/phone-title acceptance. The MIT-licensed source is public and can be built locally with Xcode 26 or newer.
