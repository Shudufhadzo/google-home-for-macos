# Home Manager 0.5.6 release verification

4 October 2026. Bundle version **0.5.6**, build **16**. Work branch `shudu/smooth-song-boundary-alignment`, based on the fetched 0.5.5 integration commit `52397b6`.

## Problem and implementation

The previous mixed-playback runtime log showed corrections about every five seconds. A new 180-second persistent-offset regression reproduced **30 seeks** with the old controller. A second regression showed the independent Cast correction loop issuing competing seeks in a mixed session. Both regressions failed before the fix and pass with the bounded policy.

`PlaybackAlignmentWindow` allows correction only after coordinated startup or while Music is held at a song boundary. Before gap correction, every fresh receiver position must pass a conservative captured-PCM tail marker. Calibration permits at most two corrections, a four-second settling interval and a twelve-second deadline. A missing/stalled timing feed has a forty-five-second drain deadline, then skips correction. Timing monitoring continues during songs without automatic seeks.

Music's installed public scripting dictionary describes `play once`, but actual tests of both implicit-current-track and explicit-track commands continued into the next queue item on this Mac. The final implementation uses public clock/state/identity reads and a guarded Pause in the final fraction, with a 350 ms lead for command latency and end-time reporting error. It resumes that remaining audio after calibration, allowing Music to advance its own existing queue. No samples are intentionally discarded and no playlist/library is reconstructed. The short boundary probe avoids the slower full metadata query near the end. A completed boundary is not held twice; repeat-one or a rewind can arm a new pass.

The source is held before initial capture for coordinated Apple Music playback, while the existing Cast/AirPlay preparation barrier remains active. Receiver sessions, encoders and live URLs survive song transitions. All Mac audio has bounded startup calibration only. Manual Next/Previous in Home Manager use the same quiet gap; direct commands inside Music remain immediate. Pause during a held gap changes resume intent, including requests from the TV playback controls.

## Checks performed

- `swift test --disable-sandbox`: **105 tests, 102 passed, three opt-in integration/physical tests skipped, zero failures**. Coverage includes startup readiness, persistent drift, competing Cast corrections, two-correction limits, buffered-tail drain, invalid/stale/future timing, shared HLS clients, native AAC stereo, capture/connection lifecycle and home-management APIs.
- `HOME_MANAGER_TEST_MUSIC_QUEUE=1 swift test --disable-sandbox --filter MusicQueueIntegrationTests`: **passed on two consecutive different songs** with the final 350 ms probe. It verified a position-preserving startup hold/resume, a boundary pause before queue advance, a two-second quiet hold, resume without a second boundary pause, and automatic advance to the next item in the existing Music queue. This is a real Music API test, not a mock and not an acoustic test.
- Universal Release packaging passed. `lipo -archs` reports **x86_64 arm64**; `vtool -show-build` reports minimum macOS **14.4** for both.
- Apple notarization submission **9d90b0fb-0b1c-4642-a201-9bcdf3c4c0dc**: **Accepted**. The app's ticket was stapled and validated before packaging.
- Final DMG passed `hdiutil verify`. Its app, mounted read-only, passed strict `codesign` verification, `stapler validate`, and `spctl --assess`: **accepted, source=Notarized Developer ID**.
- The extracted ZIP app separately passed strict signature verification, stapled-ticket validation and Gatekeeper assessment.
- `shasum -a 256 -c SHA256SUMS.txt`: **DMG and ZIP both OK**.
- `git diff --check`: passed. Generated apps/packages and temporary diagnostic logs remain outside Git.

Compiler warnings include existing Keychain deprecations, the SDK's architecture deprecation, and a Swift 5-mode sendability warning for the queue-confined Music worker. These did not prevent the build or tests.

## Physical acceptance boundary

The development app's About window was observed with **0.5.6 (16)**. Later computer-use calls repeatedly timed out, including after a tool-session reset. The fresh TV/speaker listening check could not be completed through that interface. Earlier user-confirmed steady sound, no Next chime and TV artwork belong to [0.5.4 verification](VERIFICATION-0.5.4.md); they do not prove this new song-gap policy acoustically.

The release remains a preview. The new source handoff is verified against real Music, and receiver calibration is covered by automated tests. Fresh simultaneous TV/speaker listening, another Mac/Intel runtime, and continuous sub-100 ms acoustic measurement remain separate. Timing logs measure receiver media positions rather than room sound. The quiet gap may last several seconds; explicit pause/resume or interruption recovery can still reposition live playback.
