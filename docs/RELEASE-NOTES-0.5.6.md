# Home Manager 0.5.6 — smooth playback with bounded song-gap calibration

Preview release, 4 October 2026. Requires macOS 14.4 or newer; supports Apple silicon and Intel. The DMG and ZIP contain a Developer ID signed, Apple-notarized app.

Created by **Shudufhadzo Nemulalate** · [him@shudufhadzo.com](mailto:him@shudufhadzo.com) · [shudufhadzo.com](https://shudufhadzo.com).

## Changed since 0.5.5

- **No repeated automatic seeks during a song.** The mixed drift controller previously kept correcting persistent offsets, while an independent Cast loop could issue competing adjustments. Timing is still monitored, but automatic calibration is limited to startup and quiet Apple Music song gaps.
- **Wait for all outputs at startup.** Coordinated Apple Music playback holds the source before capture begins. The preparation barrier waits for every Cast receiver and the selected AirPlay route/item, then calibration runs over silence before Music resumes.
- **Calibrate near song boundaries.** Music pauses in the final fraction of the owned track. Every output drains its buffered audio before calibration. The remaining fraction then resumes, so Music advances its existing queue normally. The final samples are retained, and no playlist is reconstructed. A short public-API timing probe uses a 350 ms lead for command latency and end-time reporting error. Music's documented `play once` parameter was ignored on the tested build and is not used.
- **Strict correction limits.** A gap permits a common-anchor adjustment and at most one follow-up, at least four seconds apart. Calibration expires after twelve seconds. Missing usable timing has a forty-five-second drain deadline and skips correction instead of seeking through an unfinished tail.
- **Normal speed and continuous sessions.** Playback remains at 1×. Capture, encoders, live URLs, Cast sessions and the AirPlay item stay connected; TV artwork continues updating in place. Next/Previous in Home Manager use the same source hold and quiet gap. Pausing while held prevents automatic resume.
- **All Mac audio:** bounded startup calibration only, because an arbitrary system mix has no reliable song boundaries.

## Validation and limits

Regression coverage reproduces the old repeated-seek behaviour and competing Cast loop, then verifies bounded windows, buffered-tail completion, stale/future timing rejection and no automatic song-body seeks. A real Music integration test verified position-preserving source hold/resume, a boundary hold, a quiet wait, and advance to the next item in the existing queue. See [release verification](VERIFICATION-0.5.6.md).

The gap can last several seconds while receiver buffers drain and calibration settles. Direct selections or skips inside Music take effect immediately there and do not receive Home Manager's held transition. Explicit pause/resume and interruption recovery can still reposition live playback.

The reported alignment target remains below 100 ms. Independent Cast and AirPlay clocks, buffering, TV processing and room acoustics mean that continuous sub-100 ms acoustic synchronisation is not guaranteed. Fresh physical listening acceptance for this boundary-calibration build remains separate from the real Music API test and automated receiver tests; earlier steady playback/artwork acceptance is documented in [0.5.4 verification](VERIFICATION-0.5.4.md).

Whole-home inventory, rooms, favourites, device display names, Home Assistant controls, management links and creator details remain available. Mixed All Mac audio requires macOS 26; Apple Music capture is available on earlier supported macOS versions. Protected source material may not be capturable.

Open the DMG and drag **Home Manager.app** to **Applications**, replacing the previous copy after quitting it. A ZIP alternative and SHA-256 checksums are included.
