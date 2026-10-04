# Multiple destinations and playback timing

Home Manager 0.5.5 preview, checked 4 October 2026. This feature sends **Mac audio**, including an Apple Music-only source, to compatible Cast receivers. It does not add screen/video mirroring or capture audio playing inside the TV.

## Use the app

1. Open **Music & speakers**. Under **Destinations**, click each individual Cast speaker/TV you want. A checkmark identifies a selected destination. Click it again, or its remove button below, to deselect it.
2. Wait for **Connected** under every selected device. A slow/disconnected receiver prevents casting to a partial set. If a connection fails, remove and select that destination to reconnect.
3. Choose **All Mac audio** or **Apple Music**, then **Cast Mac audio**. One capture and one AAC encoder serve identical audio segments to all destinations. Independent receivers load paused at a common position; playback starts after all have prepared. A receiver that starts early is paused while the others prepare if it supports pausing.
4. Adjust a destination's own slider to balance its volume, or **All destinations volume** under Now Playing to change all of them. Track changes keep the same receiver sessions and live URLs. Apple Music controls are issued once to Music, with receiver pause/resume sent to the selected destinations.
5. Synchronisation runs automatically in the background. Receiver-reported media positions are extrapolated to the same monotonic time; they do not measure when sound leaves a speaker/TV. The destination cards keep only selection, connection and volume controls.
6. Choose **Stop casting** before changing destinations. A temporary Cast control-socket interruption gets bounded retries against the same media session. A lost/taken-over receiver, exhausted recovery or startup timeout stops the whole cast and restores local source playback.

Up to eight individual receivers can be selected. A single/group cast preserves the previous startup and short live-window behaviour. Independent multi-device playback advertises sixty-four half-second segments, about thirty-two seconds, and retains at most 129 segments so recently removed URLs remain available to receivers, so a slower receiver can prepare the same beginning and live seeks stay bounded. A paused source continues generating silence to keep HLS live. When every independent receiver exposes a fresh overlapping live-seek range, resume uses a common live point; otherwise Play is broadcast to the existing media sessions.

## Google Home groups

For receiver-managed synchronisation, create a group in the Google Home phone/tablet app with compatible speakers, displays, and Google streaming receivers. Cast to that group in Home Manager. A group advertises itself as **Google Cast Group** and is one destination; selecting it replaces individual selections. Selecting an individual receiver replaces a selected group. The Mac does not know group membership, so it cannot safely combine a group and its members without conflicting sessions.

Google documents synchronous group playback and a specific list of compatible devices; first-generation Chromecast is excluded. Inclusion depends on the exact receiver, not merely a TV having Wi-Fi or Google Assistant. See [create and manage speaker groups](https://support.google.com/googlehome/answer/7174267?hl=en).

TVs, streaming receivers and external sound systems can add audio-processing delay. If a group sounds consistently offset, Google documents **device Settings → Audio → Group delay correction**. Adjust while listening to the group; that correction applies to group playback, not individual casts. See [group playback delay](https://support.google.com/googlehome/answer/6318642?hl=en).

## Samsung TV checked in this home

The native inventory identified **Samsung AU7000 50 TV**, model **UA50AU7000KXXA**, after it was powered on. Its Bonjour entry reported an **AirPlay receiver**; two UPnP descriptions also appeared. The Cast list contained **Office Speaker** (Mi Smart Speaker), **Home group**, and **Home Speakers** (both Google Cast Group). The Samsung did not advertise a Cast endpoint in that scan.

AirPlay/UPnP advertisements cannot join a Google Cast group by themselves. Home Manager 0.5.5 can instead bridge the same captured audio to Cast and the TV’s native AirPlay receiver using the workflow below. For receiver-managed Cast synchronisation, a **group-compatible Cast receiver attached to the TV** is still a separate option. Discovery combines the Samsung’s AirPlay, DIAL and MediaRenderer advertisements into one inventory card. [Samsung model support](https://www.samsung.com/africa_en/support/model/UA50AU7000KXXA/) and [Samsung AirPlay guidance](https://www.samsung.com/uk/support/tv-audio-video/what-is-screen-mirroring-and-how-do-i-use-it-with-my-samsung-tv-and-samsung-mobile-device/).

## Independent receiver correction

All LOAD requests specify normal playback rate (1×). A receiver reporting a different positive active rate stops the shared cast instead of silently playing at a different speed. A reported zero means the media clock is stopped; Cast permits this even in Playing state during priming, so it is allowed to finish buffering and is excluded from drift correction. A new item's initial Idle status is also allowed to load; Idle after it has played stops the cast. Independent sessions have different network queues, buffers and audio output processing, so coordinated commands cannot guarantee sample-accurate or echo-free output.

Automatic correction requires all selected receivers to report the same current stream and media app, a current media session, Playing at 1×, fresh position samples no more than three seconds old, seek support, and a live range containing a common correction point. A spread above 80 ms must persist across three fresh sampling rounds. Ahead receivers seek back to the slowest receiver, inside the common range with edge headroom. Corrections are separated by at least eight seconds. Speed and pitch are not adjusted. Non-seekable receivers can still play the shared stream, but automatic live correction is unavailable; group playback provides receiver-managed synchronisation.

The implementation follows [Google's media messages](https://developers.google.com/cast/docs/media/messages), [LoadRequestData](https://developers.google.com/cast/docs/reference/web_receiver/cast.framework.messages.LoadRequestData) and [LiveSeekableRange](https://developers.google.com/cast/docs/reference/web_receiver/cast.framework.messages.LiveSeekableRange). [PyChromecast's model mapping](https://github.com/home-assistant-libs/pychromecast/blob/master/pychromecast/const.py) was read to verify the virtual group model; its code is not copied or bundled.

Automated receiver-boundary tests and two real HTTP clients verify coordination/shared media. Actual audible TV-plus-speaker alignment remains a listening acceptance check with compatible hardware; a Playing acknowledgement alone does not prove it.


## Cast speakers and an AirPlay TV

1. Keep the Mac, TV and Cast speakers on the same reachable home LAN.
2. In Apple Music, choose **this Mac** as the output. Direct AirPlay inside Music can bypass the PCM capture path. Home Manager will handle the TV output.
3. In Home Manager, choose your Cast speakers or one Google Home group, then enable **Play with AirPlay** on the TV card alongside the speaker destinations.
4. Choose **Cast Mac audio**. Use the native AirPlay button in Home Manager to choose the Samsung TV. macOS handles discovery/pairing. A discovered device is not treated as an active route.
5. Home Manager serves two unlisted HLS renditions from the same captured PCM timeline: audio-only AAC for Cast, and AAC plus a Now Playing video card for the TV. The card includes the current cover, title, artist and album when Music supplies them. Cast remains paused until the AirPlay item, AirPlay route, and every Cast receiver are ready. They then start at normal speed. The original source stays muted locally; Home Manager’s own AirPlay playback is excluded from system capture to prevent feedback.
6. Play or skip tracks normally. The capture, live timelines, Cast media session and AirPlay item remain connected. The TV card updates in place. Automatic alignment runs in the background after three distinct fresh samples show more than 80 ms of drift; it targets a reported gap under 100 ms. When every Cast receiver supports a seek at the TV’s position, the app adjusts Cast while keeping the TV’s audio/video pipeline continuous. Corrections wait at least four seconds and use damped feedback to account for command/buffering delay. The destination UI contains only the selection and connection controls.

7. Use the native AirPlay picker or TV remote for TV volume. **Stop casting** stops both owned playback paths and restores source playback. A transient AirPlay route interruption pauses the Cast outputs for up to five seconds while the route returns. A lasting route loss or stream error stops the shared cast.

This is one shared audio source across two playback protocols. AirPlay and Cast maintain independent output buffers and clocks. Reported media positions do not measure TV DSP, external sound-system delay, or sound travelling through a room. Automatic alignment can help, but this feature does not guarantee continuous sub-100 ms acoustic synchronisation. The app does not measure acoustic delay automatically. Its TV video is a Now Playing card; screen mirroring and arbitrary video casting are outside this feature. Playback holds a macOS activity lease to prevent App Nap or idle system sleep during an active stream. HLS segment retention follows the [RFC 8216 sliding-window lifetime requirement](https://www.rfc-editor.org/rfc/rfc8216.html#section-6.2.2).

Mixed **All Mac audio** requires macOS 26 for persistent bundle-based exclusion of Home Manager’s player. Earlier supported macOS versions can use **Apple Music** capture. Protected source material may not be capturable; a playing UI alone is not evidence of audible output.

The implementation uses Apple’s public [AVRoutePickerView player binding](https://developer.apple.com/documentation/avkit/avroutepickerview/player), [AVPlayer AirPlay support](https://developer.apple.com/documentation/avfoundation/supporting-airplay-in-your-app), and [Core Audio tap mute behavior](https://developer.apple.com/documentation/coreaudio/catapmutebehavior), together with the existing [Cast media protocol](https://developers.google.com/cast/docs/media/messages).

Track titles and artwork in Home Manager and the TV’s encoded card update during the existing session. The default Cast receiver retains the metadata from its initial LOAD; the documented standard sender messages provide no metadata-only update command. Updating the Google Home phone’s label on every song while retaining this receiver would require a custom Web Receiver or a reload. Continuous playback takes precedence here.

Cast streaming supports a global/ULA IPv6 URL when discovery yields an IPv6 endpoint or a hostname without a resolved IPv4 address. The listener serves both address families. A transient Cast control-socket reset is retried without LAUNCH or LOAD; the receiver must still report this app’s same live stream.
