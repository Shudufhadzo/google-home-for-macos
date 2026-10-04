# Home Manager for macOS

![Home Speaker logo](Resources/HomeSpeakerLogo.png)

A native macOS home-management app, expanded from **Home Speaker**. Keep Cast devices, home-hub entities, routers, Wi-Fi extenders, and other advertised local devices together. Organize entries into rooms and favourites, control supported Home Assistant entities, and open network devices' management pages in Safari. **Music & speakers** retains Cast playback, volume, Apple Music metadata, and Mac audio streaming.

This is an independent project, not an official Google Home application. Compatibility depends on a device's protocol, exact model, firmware, and configured integrations; a manufacturer's name or a shared Wi-Fi network does not guarantee control.

[![macOS build and tests](https://github.com/Shudufhadzo/google-home-for-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/Shudufhadzo/google-home-for-macos/actions/workflows/ci.yml)

## Current development: Home Manager 0.5.4

The whole-home expansion is **unreleased source and a local development build**. It includes:

- **Your home, Favourites, and Rooms:** searchable entries with persistent local room/favourite assignments.
- **Device display names:** open a device’s Details, enter a **Display name**, and Save. Custom names appear on inventory cards, in search, and in Cast destination controls. They stay on this Mac; the advertised device name and macOS AirPlay picker keep their original names. Clear the field or choose **Use device name** to reset it.
- **Unified discovery:** advertisements from the same TV or router are reconciled into one card, retaining AirPlay, UPnP, management links, and saved room/favourite aliases. Distinct Google Home groups and hub entities remain separate.
- **Cast + AirPlay:** include an AirPlay TV using the native route picker inside Home Manager. One captured PCM timeline feeds an audio-only Cast stream and a TV stream with audio, cover art, title and artist. A preparation barrier waits for both outputs. Automatic alignment targets a reported gap below 100 ms, with automatic corrections; physical sound timing still depends on receiver buffering and TV processing.
- **Music & speakers:** select up to eight individual Cast receivers together, or one Google Home group. One capture and AAC stream feed every destination, with a coordinated start, individual/master volume, reported timeline monitoring, and capability-gated drift correction.
- **Network:** Bonjour and IPv4 SSDP discovery, the gateway reported by macOS, and saved management addresses for routers, extenders, and other devices. Saved addresses are labelled as saved; discovery is not treated as proof of device control.
- **Home Assistant:** authenticated REST connection, live state/service reads, 10-second polling, and capability-aware controls. Tokens use macOS Keychain. A failed refresh retains last-known state and disables commands until connectivity returns.
- **Connections:** setup and configuration links for Google Home, Home Assistant, Huawei, Xiaomi, and Matter. Links open in Safari.

See [multi-device playback and TV compatibility](docs/MULTI-DEVICE-CASTING.md), [device support and setup](docs/DEVICE-SUPPORT.md), [architecture and extension guide](docs/HOME-ARCHITECTURE.md), and [playback and TV-artwork verification](docs/VERIFICATION-0.5.4.md). The [display-name verification](docs/VERIFICATION-0.5.3.md) records the preceding build. The [0.5.1 playback verification](docs/VERIFICATION-0.5.1.md), [0.5.0 verification](docs/VERIFICATION-0.5.0.md) and [whole-home development notes](docs/RELEASE-NOTES-0.5.0.md) record earlier baselines.

## Published speaker-only download (0.4.2)

The existing download below is the earlier **Home Speaker** release. It does not contain the Home Manager expansion.

[**Download Home Speaker 0.4.2 for macOS (.dmg)**](https://github.com/Shudufhadzo/google-home-for-macos/releases/download/v0.4.2/Home-Speaker-0.4.2.dmg)

Open the DMG and drag **Home Speaker.app** to **Applications**. The download includes Apple silicon and Intel builds and requires macOS 14.4 or newer.

[Download the ZIP instead](https://github.com/Shudufhadzo/google-home-for-macos/releases/download/v0.4.2/Home-Speaker-0.4.2.zip) · [SHA-256 checksums](https://github.com/Shudufhadzo/google-home-for-macos/releases/download/v0.4.2/SHA256SUMS.txt) · [Release notes](https://github.com/Shudufhadzo/google-home-for-macos/releases/tag/v0.4.2)

This download is signed with a Developer ID Application certificate and notarized by Apple. The DMG opens a Finder window that shows where to drag the app for installation.

## Release status

The project is open source under the [MIT license](LICENSE). Home Manager targets macOS **14.4 or newer**. Universal packages target Apple silicon and Intel. The historical Home Speaker physical checks used a Xiaomi Mi Smart Speaker L09G; they do not validate every new device integration.

Build from source using the steps below. `./Scripts/package-release.sh` creates notarized public packages when configured with a Developer ID Application identity and `notarytool` profile; without them, it creates development packages. See [release packaging](docs/RELEASING.md), [privacy](PRIVACY.md), and [attribution](NOTICE.md).

## Build and run

Requires Xcode 26 or newer with the macOS 26 SDK to build; the resulting app targets macOS 14.4 or newer. No third-party runtime packages are required.

```sh
git clone https://github.com/Shudufhadzo/google-home-for-macos.git
cd google-home-for-macos
./Scripts/build-app.sh
open dist/HomeManager.app
```

To build both Mac architectures, use `UNIVERSAL=1 ./Scripts/build-app.sh`. The source executable remains `HomeSpeaker` and the bundle identifier remains `za.shudu.homespeaker` for continuity. The built app is **Home Manager**. This local build is ad-hoc signed; it is not the published notarized release. Quit a running copy before launching a replacement.

If macOS prompts for Local Network access, allow it. Keep local devices on the same reachable LAN/subnet. If no device appears, check **System Settings → Privacy & Security → Local Network**, then refresh. Cast devices must already be set up in the Google Home phone app. Some routers/extenders do not advertise discovery services: use **Add device** with their actual local management address.

## Connect a home hub

1. Set up Home Assistant on a supported host and add the integrations for your devices in **Settings → Devices & services**.
2. In Home Assistant, open **Profile → Security → Long-lived access tokens** and create a token for Home Manager.
3. In Home Manager, open **Connections → Connect Home Assistant**. Enter the server's root address, for example `http://homeassistant.local:8123`, and the token. Use the actual advertised port; it can differ between installations. Remote servers require HTTPS.
4. Choose **Connect**. Entities and their available controls appear in **Your home**. Open an entry for adjustments and room assignments. These assignments stay on this Mac; they do not change Home Assistant's areas.
5. Use **Connections → Device integrations** for pairing/configuration beyond the controls exposed here. **Disconnect** removes the connection and its Keychain token.

Home Assistant is optional for direct Cast and network-management links, and required for the broader smart-device controls in this version. It is not bundled or silently installed.

## Synthetic development demo

For a repeatable UI/API check without physical devices, run `python3 Scripts/mock-home-hub.py` and connect to `http://127.0.0.1:8129` with token `home-manager-local-demo`. This loopback-only fixture shows explicitly named **Demo** entities; it is not a real Home Assistant server. Test Turn on/Turn off on **Demo desk light**, open it to apply brightness, assign a room, and check **Demo offline bulb** has no active controls. Disconnect afterward and stop the fixture with Ctrl+C. Restarting resets its synthetic state; saved room/favourite assignments remain local preferences.

## App artwork and installation

The app icon is in `Resources/HomeSpeakerIcon.icns`, with the full-size source in `Resources/HomeSpeakerIconSource.png`. The transparent wordmark is `Resources/HomeSpeakerLogo.png`. Home Manager currently retains the existing artwork; the source/bundle identifiers preserve continuity.

To regenerate the icon set after changing the source image, run `./Scripts/generate-app-icon.sh`. To regenerate the matching wordmark, run `swift Scripts/generate-logo.swift`. The installation destination for the current app is `/Applications/Home Manager.app`.

## Cast Mac audio over Wi-Fi

1. In **Music & speakers → Destinations**, select the individual Cast speakers/TVs you want and wait for every destination to show **Connected**. Alternatively, select a Google Home group: the group handles its members' synchronisation. Group selection replaces individual selections to avoid conflicting sessions. Stop casting before changing destinations.
2. Choose **Apple Music** to cast only Music, or **All Mac audio** for the entire sound mix. Choose **Cast Mac audio**. Allow macOS System Audio Recording access if prompted. The app uses Apple's Core Audio tap to capture the Mac sound mix, serves one unlisted live AAC/HLS stream from the Mac, and asks each selected Cast receiver to play the same timeline. All devices must remain on the same local network. For individual receivers, the app prepares them with autoplay disabled, waits for all of them, and starts playback together at normal speed.
3. Local playback of the selected source is automatically muted using Core Audio's `mutedWhenTapped` mode. Other applications remain audible when you select Apple Music. The Mac's system volume setting is not changed.
4. When asked, allow the app's **Music** Automation access for song information and playback controls. Playback state and metadata refresh every 250 ms; artwork refreshes when the track changes. The current song is also published as music metadata to the Cast receiver for Google Home on the phone. One live media session remains connected across track changes. The app and TV card update their title and artwork in place. The standard Cast receiver retains the metadata supplied when the session started; refreshing its Google Home track label would require a new load or a custom receiver. Artwork is served temporarily over the same local connection. If access is denied, casting still works and the app shows how to enable it under **Privacy & Security → Automation**.
5. Choose **Stop casting** when finished. The app closes every owned live session and releases the audio tap, restoring local playback. A connection error, playback takeover, or startup failure on any selected destination stops the whole Mac cast. Stop in Now Playing ends a Mac audio cast; Play/Pause and track skips control Apple Music once and fan out receiver controls. The live stream advances with silence during a pause. Individual receivers that expose live seeking resume at a common live position; otherwise they receive Play on their existing sessions. In All Mac audio mode, pausing Music does not pause other applications in the sound mix.

Audio setup runs off the UI thread so macOS permission prompts do not freeze the app. Cancelling while permission is pending prevents that session from starting afterward. Replacing the app with a new build can require allowing audio recording again.

Next/Previous commands go to Music once. The capture, AAC encoders, HLS URLs, Cast media session and AirPlay item remain active across song changes. The TV card updates inside the existing video stream. Receiver buffering adds a short delay before a skip is heard; the app does not reconnect each song to discard that buffer. Pause/resume also keeps the media session open.


The speaker may take a few seconds to start. The connection adds latency, so it is not suited to video synchronization or games. The stream uses AAC at 256 kbps in half-second fragmented MP4 segments over HLS. Receiver buffering is device-dependent; this does not promise instant startup or zero capture latency. The app does not save captured audio. Music protected by DRM, including some Apple Music subscription playback, may be silent when macOS capture is used; use Bluetooth output in that case. The Cast session reaching **Playing** confirms that the speaker accepted the stream, but audible Apple Music playback still needs a listening check.

## Window layout and speaker selection

The interface adapts to the current window size. Smaller windows use one column; wide windows and full screen place speakers and casting controls beside an expanded Now Playing panel. Artwork and the playback panel grow with the available space.

Checked destination cards play together. The sliders under each selected destination control its volume; the slider under Now Playing controls all selected volumes. Independent sessions display an **estimated receiver spread**, not measured acoustic delay. Automatic alignment requires fresh timing reports and live-seek support from every receiver. Use a Google Home group for the protocol's own synchronisation and adjust group delay for a TV if needed. AirPlay TVs can join the same audio stream through **Also play on an AirPlay TV**. Choose the TV in Home Manager’s native AirPlay picker after starting capture. Use this Mac as Music’s output; Home Manager supplies the AirPlay output itself. UPnP-only TVs retain their compatibility limits. See the [mixed playback guide](docs/MULTI-DEVICE-CASTING.md#cast-speakers-and-an-airplay-tv). Home Manager does not change the Mac's default sound output. If you want Bluetooth instead of Cast, pair and select that output through macOS System Settings → Sound.

## Shared playback from other devices

When your phone or another Cast app starts music, connect Home Manager to the same speaker to see the receiver's title, artist, and available album cover. The artwork loads from the image URL provided by the active Cast session. If the sender provides no image, or the image cannot be fetched, the app shows its music placeholder. Selecting a speaker joins its current session without taking over playback.

## Cast implementation and limits

- Native SwiftUI interface; a reusable `HomeCore` library for entity/capability models, endpoint policy, Home Assistant REST, and SSDP description parsing; macOS Bonjour/SSDP discovery and Keychain persistence; existing Cast V2/Core Audio/HLS modules.
- Google's Home APIs target iOS and Android. This native macOS app opens Google Home and its automations in Safari; it does not directly synchronize Google account devices or commission Matter accessories. Existing Home Assistant integrations provide the broader device-control route.
- The Cast V2 connection accepts the receiver's self-signed local certificate. It should be used only on a trusted local network.
- Capture preserves stereo 16-bit PCM at the device sample rate, then Apple's AVAssetWriter encodes AAC at 256 kbps and produces half-second fragmented MP4 segments. No third-party encoder is bundled. Audio segments and playlists remain in memory and are removed when casting stops.
- Single/group playback retains the existing six-segment live window and twenty-segment history. Independent multi-device playback keeps a bounded sixty-four-segment window/history (about thirty-two seconds), preserving the same beginning while receivers prepare. The startup hint switches to the live edge after preparation. Encoding uses a one-second bounded PCM queue and stops on overload. All receivers consume identical encoded segments. All Mac audio remains a continuous mix, independent of Music's playback state.
- `CastSessionCoordinator` owns receiver connections and the start barrier; `CastSyncPlanner` compares fresh positions at a common time and corrects sustained drift by seeking ahead receivers back to the slowest one, only inside an overlapping live window. It does not change pitch or speed to chase drift. Independent receiver sessions are best effort; receiver timestamps do not include TV/audio-system processing delay. Google Home groups provide receiver-managed synchronisation. AirPlay and UPnP discovery do not create Cast compatibility. See [the multi-device guide](docs/MULTI-DEVICE-CASTING.md).
- Regression tests cover multiple selections, start/confirmation barriers, stale callbacks, shared HTTP media, drift/timing constraints, bounded buffers, cancellation, native stereo AAC, and the whole-home APIs. The existing physical Cast test remains opt-in and is separate from audible multi-device acceptance.
- Device listening checks are separate from digital audio tests. A Cast session reporting Playing does not by itself prove audible quality or local speaker muting.

## Historical speaker validation (0.4.x)

Earlier listening checks on the Xiaomi L09G confirmed audible casting, a silent Mac, and clear sound. The user subsequently measured **12–13 seconds of Play/Pause delay in the WAV build**. Version 0.4.0 replaces that transport and adds direct receiver playback synchronization; the previous listening acceptance does not validate this new transport.

Fifteen automated tests pass locally, including artwork metadata lifecycle checks and an HTTP HLS test that feeds distinct stereo tones through the native AAC encoder, fetches the resulting fragments, decodes them, verifies non-silent independent channels, and checks that startup and ongoing delivery work even when a paused app supplies no audio callbacks. These tests do not measure acoustic speaker latency. A separate opt-in physical L09G test passed a 20-second pause followed by direct Play and 15 seconds of stable receiver playback; the receiver reported `PLAYING` in the same second as the Play command. This excludes Apple Music polling and does not measure acoustic output. Earlier 0.4.1 testing used a live-stream reload on Resume, which took about 0.93 seconds to receive a `PLAYING` acknowledgment. Version 0.4.1 was also installed and visually checked while joining an existing L09G session started outside the Mac app: its available album cover, title, and artist appeared together.

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
