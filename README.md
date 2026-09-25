# Google Home for macOS — Home Speaker

![Home Speaker logo](Resources/HomeSpeakerLogo.png)

A native, local macOS app for a Xiaomi Mi Smart Speaker (L09G) and other Google Cast audio devices. It discovers receivers on the same Wi-Fi network, connects to one, shows the current media title, and controls play, pause, stop, supported queue skips, and speaker volume. Apple Music casts show the song, artist, album, available artwork, and playback position; the transport buttons control Music on the Mac. It streams captured Mac sound over Wi-Fi to the selected Cast speaker.

**An independent native macOS app for Google Cast speakers.** This is not an official Google Home application and is not affiliated with Google, Apple, or Xiaomi.

[![macOS build and tests](https://github.com/Shudufhadzo/google-home-for-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/Shudufhadzo/google-home-for-macos/actions/workflows/ci.yml)

## Download Home Speaker for macOS

[**Download Home Speaker 0.4.1 for macOS (DMG)**](https://github.com/Shudufhadzo/google-home-for-macos/releases/download/v0.4.1/Home-Speaker-0.4.1-universal-development.dmg)

Open the DMG and drag **Home Speaker.app** to **Applications**. The download includes Apple silicon and Intel builds and requires macOS 14.4 or newer.

[Download the ZIP instead](https://github.com/Shudufhadzo/google-home-for-macos/releases/download/v0.4.1/Home-Speaker-0.4.1-universal-development.zip) · [SHA-256 checksums](https://github.com/Shudufhadzo/google-home-for-macos/releases/download/v0.4.1/SHA256SUMS.txt) · [Release notes](https://github.com/Shudufhadzo/google-home-for-macos/releases/tag/v0.4.1)

**Development preview:** this build is ad-hoc signed and has not been notarized by Apple, so macOS may block it after download. If that happens, use the build-from-source instructions below. A notarized installer requires Developer ID signing and Apple notarization.

## Release status

Version **0.4.1** is an early open-source development preview under the [MIT license](LICENSE). The app runs on macOS **14.4 or newer**. Universal packages target Apple silicon and Intel; physical speaker testing so far has been on Apple silicon with a Xiaomi Mi Smart Speaker L09G.

Build from source using the steps below. Development DMG/ZIP packages can be generated with `./Scripts/package-release.sh`; they are ad-hoc signed and **not notarized**. A public, notarized installer requires a Developer ID Application certificate. See [release packaging](docs/RELEASING.md), [privacy](PRIVACY.md), and [attribution](NOTICE.md).

## Build and run

Requires Xcode 26 or newer with the macOS 26 SDK to build; the resulting app targets macOS 14.4 or newer. No third-party runtime packages are required.

```sh
git clone https://github.com/Shudufhadzo/google-home-for-macos.git
cd google-home-for-macos
./Scripts/build-app.sh
open dist/HomeSpeaker.app
```

To build both Mac architectures, use `UNIVERSAL=1 ./Scripts/build-app.sh`. To install your locally built app, quit any running copy, then copy `dist/HomeSpeaker.app` to Applications as **Home Speaker.app**. For a notarized DMG release, open the DMG and drag **Home Speaker** into **Applications**.

If macOS prompts for Local Network access, allow it. Keep your Mac and speaker on the same Wi-Fi/subnet. If no speaker appears, check **System Settings → Privacy & Security → Local Network**, then rescan. The speaker must already be set up in the Google Home phone app.

## App artwork and installation

The app icon is in `Resources/HomeSpeakerIcon.icns`, with the full-size source in `Resources/HomeSpeakerIconSource.png`. The transparent wordmark is `Resources/HomeSpeakerLogo.png`. The build script embeds both artwork files and sets `CFBundleIconFile` so Finder, Dock, and the app window use the new icon.

To regenerate the icon set after changing the source image, run `./Scripts/generate-app-icon.sh`. To regenerate the matching wordmark, run `swift Scripts/generate-logo.swift`. The installation destination is `/Applications/Home Speaker.app`.

## Cast Mac audio over Wi-Fi

1. Select the speaker card and wait for **Connected**.
2. Choose **Apple Music** to cast only Music, or **All Mac audio** for the entire sound mix. Choose **Cast Mac audio**. Allow macOS System Audio Recording access if prompted. The app uses Apple's Core Audio tap to capture the Mac sound mix, serves an unlisted live AAC/HLS stream from the Mac, and asks the speaker's Cast receiver to play it. Both devices must remain on the same local network.
3. Local playback of the selected source is automatically muted using Core Audio's `mutedWhenTapped` mode. Other applications remain audible when you select Apple Music. The Mac's system volume setting is not changed.
4. When asked, allow **Home Speaker → Music** Automation access for song information and playback controls. Playback state and metadata refresh every 250 ms; artwork refreshes when the track changes. The current song is also published as music metadata to the Cast receiver for Google Home on the phone. Track changes load a fresh media item and stream URL so connected Google Home apps receive a new title together with the artwork. Artwork is served temporarily over the same local connection. If access is denied, casting still works and the app shows how to enable it under **Privacy & Security → Automation**.
5. Choose **Stop casting** when finished. The app closes the stream and releases the audio tap, restoring local playback. Connection errors, receiver playback changes, and startup timeouts also release capture. Stop in Now Playing ends a Mac audio cast; Play/Pause and track skips control Apple Music. When casting Apple Music, playback changes made directly in Music also send Play/Pause to the receiver, and Pause reaches the receiver directly, while Resume reloads at the live edge instead of replaying audio buffered before the pause. In All Mac audio mode, pausing Music does not pause other applications on the speaker.

Audio setup runs off the UI thread so macOS permission prompts do not freeze the app. Cancelling while permission is pending prevents that session from starting afterward. Because this development build is signed locally, replacing its binary can require allowing audio recording again.

When using Next/Previous, the app stops the old Cast stream, discards its queued samples, pauses the new Music track at its beginning, and resumes into a fresh segmented audio timeline. This removes the old song's buffered tail. The new timeline retains a short window while the receiver connects; startup and slow networks can still affect when its first audio is heard. The same preparation is applied when Music changes tracks externally. The speaker can still need a short silent buffering interval; this is not a zero-latency Cast transport.

The speaker may take a few seconds to start. The connection adds latency, so it is not suited to video synchronization or games. The stream uses AAC at 256 kbps in half-second fragmented MP4 segments over HLS. Receiver buffering is device-dependent; this does not promise instant startup or zero capture latency. The app does not save captured audio. Music protected by DRM, including some Apple Music subscription playback, may be silent when macOS capture is used; use Bluetooth output in that case. The Cast session reaching **Playing** confirms that the speaker accepted the stream, but audible Apple Music playback still needs a listening check.

## Window layout and speaker selection

The interface adapts to the current window size. Smaller windows use one column; wide windows and full screen place speakers and casting controls beside an expanded Now Playing panel. Artwork and the playback panel grow with the available space.

The selected speaker card is the Cast destination. Home Speaker does not change the Mac's default sound output. If you want Bluetooth instead of Cast, pair and select that output through macOS System Settings → Sound.

## Shared playback from other devices

When your phone or another Cast app starts music, connect Home Speaker to the same speaker to see the receiver's title, artist, and available album cover. The artwork loads from the image URL provided by the active Cast session. If the sender provides no image, or the image cannot be fetched, the app shows its music placeholder. Selecting a speaker joins its current session without taking over playback.

## Implementation and limits

- Native SwiftUI interface; Bonjour (`_googlecast._tcp`) discovery; a small Cast V2 client over the local network; Core Audio capture; a temporary local HTTP audio stream.
- Google's Home API samples target iOS and Android. This native macOS app does not manage Google Home account devices or routines. Google's web controls and phone app remain separate, and initial speaker setup still needs the phone app.
- The Cast V2 connection accepts the receiver's self-signed local certificate. It should be used only on a trusted local network.
- Capture preserves stereo 16-bit PCM at the device sample rate, then Apple's AVAssetWriter encodes AAC at 256 kbps and produces half-second fragmented MP4 segments. No third-party encoder is bundled. Audio segments and playlists remain in memory and are removed when casting stops.
- The live playlist advertises six recent segments (about three seconds), retaining twenty for in-flight requests. Encoding uses a one-second bounded PCM queue and stops on overload. Pausing an Apple Music cast pauses the receiver directly. HLS keeps advancing with silence when the capture tap supplies no samples, and Resume reloads at the live edge instead of replaying the paused backlog. All Mac audio remains a continuous mix, independent of Music's playback state.
- Regression tests cover stereo channel separation, buffered capture, overload reporting, real HTTP HLS delivery, native AAC decoding, silent startup, continuous live delivery, bounded playlist history, separate artwork, song identity, and cancellation. The app supports one receiver at a time and does not synchronize groups.
- Device listening checks are separate from digital audio tests. A Cast session reporting Playing does not by itself prove audible quality or local speaker muting.

## Validation

Earlier listening checks on the Xiaomi L09G confirmed audible casting, a silent Mac, and clear sound. The user subsequently measured **12–13 seconds of Play/Pause delay in the WAV build**. Version 0.4.0 replaces that transport and adds direct receiver playback synchronization; the previous listening acceptance does not validate this new transport.

Fifteen automated tests pass locally, including artwork metadata lifecycle checks and an HTTP HLS test that feeds distinct stereo tones through the native AAC encoder, fetches the resulting fragments, decodes them, verifies non-silent independent channels, and checks that startup and ongoing delivery work even when a paused app supplies no audio callbacks. These tests do not measure acoustic speaker latency. A separate opt-in physical L09G test passed a 20-second pause followed by a live-stream reload and 15 seconds of stable receiver playback. Receiver acknowledgments measured about 0.06 seconds for Pause and 0.93 seconds for Resume; these exclude Apple Music polling and do not measure acoustic output. The user accepted the casting progress before requesting the adaptive layout update. Version 0.4.1 was also installed and visually checked while joining an existing L09G session started outside the Mac app: its available album cover, title, and artist appeared together.

Run `swift test --disable-sandbox` to check audio conversion and streaming. The HTTP test needs permission to open a loopback network listener. The physical test is skipped by default. To deliberately take over a test receiver with silent generated audio, run `HOME_SPEAKER_TEST_HOST=<receiver-host> swift test --disable-sandbox --filter PhysicalCastTests`.

## Contributing and support

See [CONTRIBUTING.md](CONTRIBUTING.md) for build and test instructions and [SECURITY.md](SECURITY.md) for private vulnerability reporting. For ordinary bugs, include the speaker model, macOS version, audio source, and reproduction steps in a GitHub issue.

## License

[MIT](LICENSE), copyright 2026 Shudufhadzo Nemulalate. Third-party names, system frameworks, and runtime music/artwork retain their own rights; see [NOTICE.md](NOTICE.md).

## Sources

- [Google Cast overview](https://developers.google.com/cast/docs/overview)
- [Google Cast media protocol](https://developers.google.com/cast/docs/media/messages)
- [Apple Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Google Home for web capabilities](https://support.google.com/googlehome/answer/9241220)
- [Xiaomi Mi Smart Speaker L09G manual](https://alsgp0.fds.api.xiaomi.com/09usermanual/CC-L09G_UserManual_V4.9_230504.pdf)
- [PyChromecast](https://github.com/home-assistant-libs/pychromecast), [Casita](https://github.com/david-kuehn/casita), [Mkchromecast](https://github.com/muammar/mkchromecast), and [GHomeBar](https://github.com/paolorotolo/GHomeBar) informed the feature split; their code is not copied into this app.
