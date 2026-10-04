# Home Manager 0.5.5 release verification

Release date: 4 October 2026. Bundle version 0.5.5, build 15.

This release intentionally depends on the five accepted local commits after the fetched GitHub integration baseline `e671354`: whole-home management, multiple Cast destinations, unified TV discovery and AirPlay playback, device display names, and continuous shared playback. The creator-credit update is isolated on `shudu/creator-credit-home-manager-release`.

## Scope

- Add **About Home Manager** to the app menu and sidebar. Show **Created by Shudufhadzo Nemulalate**, `him@shudufhadzo.com`, and `https://shudufhadzo.com` as clickable links, plus the version/build read from the bundle.
- Add matching creator details to the README and bundled attribution notice.
- Update the README, privacy description, playback guide and release packaging notes to reflect the current whole-home app, continuous Cast/AirPlay sessions, TV artwork and background timing correction.
- Publish the current source and a versioned universal preview download rather than pointing new users at the earlier speaker-only release.

## Playback evidence carried forward

Playback source is unchanged from `0227bea`. The user confirmed **“No chime; TV updates”** after Next, then **“Both play steadily; TV artwork shows”** on the final playback build. A separate physical control-socket recovery test kept the same media session and content URL. See [0.5.4 verification](VERIFICATION-0.5.4.md).

Continuous sub-100 ms acoustic synchronisation is still unverified. The earlier receiver logs include larger excursions, and no microphone measurement was made. A fresh Home Assistant/Intel/second-Mac physical acceptance check is separate from build, packaging and notarization.

## Release checks

- `swift test --disable-sandbox`: **98 tests, 96 passed, two opt-in physical tests skipped, zero failures**.
- The native app launched on this Mac. The sidebar opens **About Home Manager**, showing version **0.5.5 (15)**, the exact creator credit, a `mailto:him@shudufhadzo.com` link and the portfolio link. The app menu also contains **About Home Manager**. The layout was visually inspected without clipped text.
- The portfolio HTTPS address responded with HTTP 200. No email was sent.
- `Scripts/package-release.sh`: universal Release build passed. `lipo -archs` reports **x86_64 arm64**; `vtool -show-build` confirms a minimum OS of **14.4** for both architectures. Build warnings include existing deprecated Keychain calls and an SDK architecture deprecation; they did not prevent the build.
- Apple notarization submission **73664fa7-014d-4820-a2af-f5333e4d51d1**: **Accepted**. The app's ticket was stapled and validated before packaging.
- The final DMG passed `hdiutil verify`. After mounting it read-only, the contained **Home Manager.app** passed strict `codesign` verification, `stapler validate`, and `spctl --assess`: **accepted, source=Notarized Developer ID**.
- The extracted ZIP app separately passed strict signature verification, stapled-ticket validation and Gatekeeper assessment.
- `shasum -a 256 -c SHA256SUMS.txt`: **DMG and ZIP both OK**.
- `git diff --check`: passed. Generated bundles, packages, signing credentials and temporary logs remain outside Git.

The versioned [GitHub release](https://github.com/Shudufhadzo/google-home-for-macos/releases/tag/v0.5.5) contains **Home-Manager-0.5.5.dmg**, **Home-Manager-0.5.5.zip** and **SHA256SUMS.txt**. The release is marked as a preview; physical acceptance on another Mac and broader device certification remain separate.
