# Home Speaker for Mac

![Home Speaker logo](Resources/HomeSpeakerLogo.png)

A native, local macOS app for a Xiaomi Mi Smart Speaker (L09G) and other Google Cast audio devices. It discovers receivers on the same Wi-Fi network, connects to one, shows the current media title, and controls play, pause, stop, supported queue skips, and speaker volume. It can stream captured Mac sound over Wi-Fi or select a paired Bluetooth speaker as the Mac's audio output.

This is an independent prototype. It is not affiliated with Google or Xiaomi.

## Build and run

Requires macOS 14.4 or later and Xcode command-line tools. No third-party runtime packages are required.

```sh
./Scripts/build-app.sh
open dist/HomeSpeaker.app
```

If macOS prompts for Local Network access, allow it. Keep your Mac and speaker on the same Wi-Fi/subnet. If no speaker appears, check **System Settings → Privacy & Security → Local Network**, then rescan. The speaker must already be set up in the Google Home phone app.

## App artwork and installation

The app icon is in `Resources/HomeSpeakerIcon.icns`, with the full-size source in `Resources/HomeSpeakerIconSource.png`. The transparent wordmark is `Resources/HomeSpeakerLogo.png`. The build script embeds both artwork files and sets `CFBundleIconFile` so Finder, Dock, and the app window use the new icon.

To regenerate the icon set after changing the source image, run `./Scripts/generate-app-icon.sh`. To regenerate the matching wordmark, run `swift Scripts/generate-logo.swift`. The currently installed copy is `/Applications/Home Speaker.app`.

## Cast Mac audio over Wi-Fi

1. Select the speaker card and wait for **Connected**.
2. Choose **Cast Mac audio**. Allow macOS System Audio Recording access if prompted. The app uses Apple's Core Audio tap to capture the Mac sound mix, serves an unlisted live WAV stream from the Mac, and asks the speaker's Cast receiver to play it. Both devices must remain on the same local network.
3. Choose **Stop casting** when finished. The app closes the stream and releases the audio tap.

The speaker may take a few seconds to start. The connection adds latency, so it is not suited to video synchronization or games. A Cast receiver can decline the live WAV format. The app does not save captured audio. Music protected by DRM, including some Apple Music subscription playback, may be silent when macOS capture is used; use Bluetooth output in that case. The Cast session reaching **Playing** confirms that the speaker accepted the stream, but audible Apple Music playback still needs a listening check.

## Use Mac audio over Bluetooth

1. On the L09G, say **“Hey Google, pair Bluetooth.”** Alternatively, use the phone's Google Home app: speaker tile → Settings → Audio → Paired Bluetooth devices → Enable Pairing Mode.
2. In this app, choose **Bluetooth settings** and pair the speaker in macOS.
3. Choose the speaker under **Sound output**. This changes the Mac's default audio output, so all ordinary Mac audio plays through it.

Bluetooth output is separate from Cast playback. It routes ordinary Mac sound, including protected music, through the system's normal output path. Bluetooth may introduce some latency.

## Implementation and limits

- Native SwiftUI interface; Bonjour (`_googlecast._tcp`) discovery; a small Cast V2 client over the local network; Core Audio capture and output selection; a temporary local HTTP audio stream.
- Google's Home API samples target iOS and Android. This native macOS app does not manage Google Home account devices or routines. Google's web controls and phone app remain separate, and initial speaker setup still needs the phone app.
- The Cast V2 connection accepts the receiver's self-signed local certificate. It should be used only on a trusted local network.
- The live Wi-Fi stream is lossless PCM and uses more bandwidth than compressed audio. The app supports one receiver at a time and does not synchronize groups.
- On the local L09G, discovery, Cast connection, volume/status reading, and a live media session were observed. Audible Mac audio, Apple Music protected content, Bluetooth playback, and every queue control have not been independently verified.

## Sources

- [Google Cast overview](https://developers.google.com/cast/docs/overview)
- [Google Cast media protocol](https://developers.google.com/cast/docs/media/messages)
- [Apple Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Google Home for web capabilities](https://support.google.com/googlehome/answer/9241220)
- [Xiaomi Mi Smart Speaker L09G manual](https://alsgp0.fds.api.xiaomi.com/09usermanual/CC-L09G_UserManual_V4.9_230504.pdf)
- [PyChromecast](https://github.com/home-assistant-libs/pychromecast), [Casita](https://github.com/david-kuehn/casita), [Mkchromecast](https://github.com/muammar/mkchromecast), and [GHomeBar](https://github.com/paolorotolo/GHomeBar) informed the feature split; their code is not copied into this app.
