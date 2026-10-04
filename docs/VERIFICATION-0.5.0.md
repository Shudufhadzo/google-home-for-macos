# Home Manager 0.5.0 development verification

Checked locally on 3 October 2026 on branch `shudu/whole-home-management`. This record describes development evidence, not a public release or certification of every device in the support matrix.

## Automated checks

`swift test --disable-sandbox --scratch-path .build` completed successfully: **35 passed, 1 skipped, 0 failures** across the app and `HomeCore` test targets. The opt-in physical Cast receiver test was skipped; it takes over the configured receiver and needs a deliberate hardware test setup.

The checks cover the existing audio/protocol behaviour and native AAC/HLS delivery, authenticated Home Assistant requests and explicit service targets, server service-catalog decoding, entity feature masks, range validation, scenes without activation timestamps, local/HTTPS address policy, root UPnP descriptions, actual loopback HTTP transport and redirect rejection, local persistence, failed reconnect preservation, stale/disconnected responses, and credential lookup outside the UI thread.

The managed command sandbox blocked the system AAC encoder during the initial run. The full suite passed when run with normal macOS access. Source audio modules were not changed to work around that environmental restriction.

## Native application checks

The SwiftUI app was launched and exercised with `Scripts/mock-home-hub.py`, an explicitly synthetic server bound to `127.0.0.1:8129`. It imported nine Demo entities. These checks do not establish compatibility with a real Home Assistant server or physical appliances.

- **Control and observed state:** Demo desk light changed from Off to On after its service request. A brightness adjustment was applied and the returned value appeared in the device sheet. The final build exposed Run on an unactivated Demo scene with an `unknown` state; invoking it returned the fixture's activation timestamp.
- **Capability limits:** the unavailable demo bulb had no action buttons; sensor state remained readable. Typed controls were shown only for the supported entities/services.
- **Persistence and recovery:** room/favourite assignments and a saved local management address survived relaunch. Reconnect to the same server retained annotations. Saved credentials restored on relaunch of the unchanged binary. An ad-hoc rebuild's denied access to an earlier Keychain item returned an actionable reconnect message promptly; it did not prevent the window from rendering.
- **Connection loss:** after stopping the fixture, the app retained Last known states and disabled its hub controls. Restarting the fixture allowed polling to recover.
- **Configuration handoff:** the saved demo network-device management button opened the fixture page in Safari. This proves the browser handoff, not authentication or configuration of real router firmware.
- **Existing interface:** Music & speakers retained All Mac audio / Apple Music selection, playback controls, and the Cast workflow. No physical receiver was connected during this check.
- **Cleanup:** the temporary saved device and demo room/favourite assignments were cleared; the synthetic bridge was disconnected, its test token removed, the test browser tab closed, and the fixture server stopped. The final development app remained open. The installed Home Speaker app was preserved.

## Actual LAN observation

The app read macOS's current IPv4 gateway and discovered this Mac's advertised AirPlay service via Bonjour. No Cast receiver or genuine Home Assistant instance was observed in this check.

The native SSDP multicast send returned **No route to host** on this Mac's current network. The app displayed the failure and retained its gateway/Bonjour inventory. UPnP parser tests passed, but end-to-end SSDP device discovery remains unverified on a multicast-capable LAN. Local Network permission, routing, VLAN/client isolation, and equipment behaviour need to be checked during hardware acceptance.

## Build and bundle

`UNIVERSAL=1 ./Scripts/build-app.sh` succeeded with normal macOS access. The resulting `dist/HomeManager.app` passed strict code-signature verification and Info.plist validation. `lipo` reported `x86_64 arm64`; both Mach-O slices declared a minimum macOS version of 14.4. The native execution checks used the current Apple silicon Mac; Intel and macOS 14.4 runtime behaviour were not separately exercised.

This bundle is **ad-hoc signed**, with no distribution TeamIdentifier. No new Developer ID package, notarization, GitHub CI result, public download, or release approval is claimed. Existing Home Speaker 0.4.2 packages remain separate.

Build warnings include the toolchain's Intel architecture deprecation notice and the intentionally isolated legacy Keychain interaction compatibility calls described in [the architecture guide](HOME-ARCHITECTURE.md). The latter decline optional authentication dialogs without changing Keychain item permissions; modern `LAContext` alone did not suppress legacy login-Keychain approval in the native check.

See [device support and setup](DEVICE-SUPPORT.md) for the implemented capability matrix and [release verification](RELEASING.md) for the additional hardware, signing, and final-package checks needed before publication.
