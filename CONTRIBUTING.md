# Contributing

Use Xcode 26 or newer (macOS 26 SDK) to build. The deployment target is macOS 14.4.

1. Fork the repository and create a focused branch.
2. Run `swift test --disable-sandbox`. The streaming tests open a loopback network listener.
3. Run `./Scripts/build-app.sh` and check the native app.
4. Explain the user-visible change and the checks you performed in your pull request.

For casting changes, report the speaker model, macOS version, audio source, observed delay, and whether the check was an automated sample test or a physical listening test. Verify that Stop restores local playback and that skips do not play buffered samples from the previous track. Do not attach personal audio recordings, credentials, network addresses, or an entire private music library to issues.

Contributions are accepted under the MIT license. Keep changes small and include a regression for reproducible audio or protocol defects.
