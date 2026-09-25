# Home Speaker 0.4.2

This update shortens the pause-to-play path for Apple Music casts. The speaker now receives a direct Play command on Resume. The live AAC stream advances with silence while paused, so the app does not need to reload the Cast player and wait for a new startup buffer. Song changes still start a fresh stream to avoid hearing the previous song after a skip.

The macOS download is now named `Home-Speaker-0.4.2.dmg`. When opened, its Finder window is titled **Drag Home Speaker to Applications** and shows the app, a drag arrow, and the Applications shortcut. The app inside is a universal Apple silicon and Intel build, signed with Developer ID and notarized by Apple. A ZIP download and SHA-256 checksums are also available.

Fifteen automated tests passed. In an opt-in silent hardware test on the Xiaomi Mi Smart Speaker L09G, direct Play returned the receiver to `PLAYING` in the same second after a 20-second pause and remained stable for 15 seconds. This is a receiver-status result; audible Apple Music resume timing has not been measured for this build.

Home Speaker is an independent open-source app. Initial speaker setup still requires the Google Home phone app. Mac audio casting remains subject to Google Cast buffering and macOS capture permissions. The app is not affiliated with Google, Apple, or Xiaomi.
