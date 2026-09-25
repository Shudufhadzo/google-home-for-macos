# Home Speaker 0.4.0 — casting latency

Addresses a user-measured 12–13 second delay in the continuous WAV transport.

- Replaces the continuous WAV response with native AAC at 256 kbps, half-second fragmented MP4 segments, and a bounded live HLS playlist. Audio stays in memory. No external encoder or runtime package is bundled.
- Observes Music playback state every 250 ms. When the selected source is Apple Music, Play/Pause is also sent directly to the receiver. The stream stays live during pauses, and Resume reloads at the live edge so it cannot replay a long silence backlog.
- Retains automatic local muting, stereo capture, fresh song identities, title/artwork publication, and release of the capture tap on Stop.
- The window adapts to full screen with a two-column layout and a larger Now Playing panel. The Mac sound-output picker and Bluetooth routing controls have been removed from the Cast interface.
- All Mac audio remains a continuous mix; Music's Pause cannot pause unrelated applications.

## Validation

Thirteen automated tests passed, including real HTTP delivery and native AAC decoding of independent stereo tones, bounded playlist history, silent startup, continuous live delivery, metadata, and capture cancellation. The universal native app builds for Apple silicon and Intel. A separate L09G protocol test passed a 20-second pause and resumed through a fresh live LOAD in about 0.93 seconds, remaining active for the following 15 seconds. Pause acknowledgment was about 0.06 seconds. These are receiver status timings, not acoustic latency measurements.

This development build is ad-hoc signed and is not Apple-notarized. Public installer signing remains a separate release gate.
