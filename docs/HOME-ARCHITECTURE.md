# Whole-home architecture

## Modules and ownership

`HomeCore` is an independent Swift library with no AppKit/SwiftUI/CoreAudio dependencies. It contains device categories, source IDs, JSON/entity decoding, capability resolution, typed commands, endpoint policy, the Home Assistant REST client/transport interface, and SSDP/UPnP parsing. New clients can reuse it without importing the macOS executable. The package currently targets macOS; a future iOS product needs its own app target, entitlements, SDK integration, and tests.

`HomeSpeaker` remains the macOS executable and source target. `HomeSpeakerApp` owns the existing `SpeakerModel` and the new observable `HomeModel`. The root window starts/stops them; navigating between home, network, connections, and music does not end a cast. The bundle ID remains `za.shudu.homespeaker` to preserve permission/preferences continuity. The displayed product name and new build output are Home Manager.

`HomeModel` coordinates local discovery, imported hub state, typed device commands, settings, and the token vault. `HomeNetworkDiscovery` uses Bonjour, a macOS IPv4 route snapshot, and `SSDPSearch`'s bounded multicast request. Network announcements produce inventory/configuration links; they never manufacture device controls.

`SpeakerModel` owns one Core Audio tap, PCM relay, AAC encoder/server and Apple Music monitor. `CastSessionCoordinator` owns separate Cast V2 connections for every selected endpoint. It prepares each receiver with the same URL, autoplay disabled and a common starting position, waits for all independent receivers, then broadcasts playback or a supported common live seek. Confirmation requires every receiver to report the expected content as Playing. A failed/taken-over receiver stops every owned live session and releases capture; generations reject late callbacks from retired connections. Track transitions cancel all old media before routing samples into one new timeline. A Google Home group is selected exclusively as one virtual endpoint and manages its own member clocks.

`CastSyncPlanner` estimates fresh media positions at one monotonic time, checks normal playback speed, media/app/session identity and overlapping live-seek ranges, then proposes seeks for sustained drift. Three distinct fresh rounds above 250 ms are required; corrections have an eight-second cooldown. Paused/buffering, stale, foreign, non-seekable, or non-overlapping streams are not corrected. It does not measure acoustic delay or synchronise independent AirPlay/UPnP devices with Cast. See [multi-device playback](MULTI-DEVICE-CASTING.md) for the full contract.

## Identity and persistence

- Cast IDs retain the existing service ID under a `cast:` namespace.
- Hub entity IDs include a saved bridge UUID and the server's `entity_id` under `ha:`. Reconnecting the same server migrates local room/favourite annotations to the new credential record.
- Bonjour IDs include instance/type/domain; UPnP IDs use the root USN UUID with the service suffix removed. Gateway IDs use the observed address. Manual devices use persisted UUIDs. Network entry identity can change when hardware changes its service identity or address; names are never treated as proof of identity.
- Hub entities and Cast/native LAN records are not globally deduplicated by friendly name. Counts explicitly distinguish Cast devices, network entries, and hub entities.
- `HomeSettingsStore` stores only versioned JSON for manual addresses, rooms/favourites, and the bridge ID/address in UserDefaults. The Keychain holds the long-lived token. Raw imported state and audio are not persisted by the new home module.

Credential operations run on a serial actor outside the main UI executor. They decline optional authentication dialogs and report failure so the inventory remains usable when the login Keychain is locked or an ad-hoc rebuild no longer has access to an earlier token. `LAContext.interactionNotAllowed` is paired with the legacy Keychain interaction flag because macOS desktop `SecItem` calls use the login Keychain here. The latter is a deprecated compatibility API required for this implementation; its prior process-local setting is restored after each operation. It does not unlock the vault or change access rules. Distribution signing and Keychain access must be verified separately when packaging a release.

## API correctness and lifecycle

The Home Assistant client reads state and the service catalog concurrently. `HomeControls` combines the entity domain, available state, advertised feature masks/attributes, and actual server services to resolve a typed command. It emits an explicit target rather than unrestricted service execution. State is read again after a successful service call; the UI never switches to a synthetic success state. Device physical behaviour still depends on its integration.

Authentication failures, timeouts, and connection loss retain the last observed state and disable controls. Generation IDs prevent late responses from reattaching disconnected/replaced servers. A replacement connection is validated and its new Keychain item/settings saved before the old client is retired; a failed reconnect preserves the previous connection. Disconnect removes the token. Network scans have separate generations and bounded work, and obsolete callbacks are rejected.

The default HTTP transport uses an ephemeral URLSession without shared cookies or cache, normal certificate validation, 10-second request / 15-second resource timeouts, and no redirect following. HTTP is accepted only for defined local host forms; HTTPS can address a user-configured remote server. Discovery URLs require local hosts, and UPnP presentation URLs must stay on the description's host.

## Adding an integration

1. Establish the exact protocol, model/firmware compatibility, credentials, and supported actions using primary docs or a maintained open-source implementation. Add the source and limits to `DEVICE-SUPPORT.md`.
2. Put platform-neutral protocol/decoding/command logic in `HomeCore`, behind an injectable transport. Keep hardware/OS-specific discovery, credentials, and UI in the app.
3. Use a source-namespaced stable device ID. Do not merge devices by display name, IP subnet, or manufacturer alone.
4. Advertise only implemented controls. Gate them on negotiated/reported features and current availability. Network-changing settings need a firmware-specific adapter and a user-facing apply/recovery flow.
5. Add meaningful fixture tests for actual message formats, authorization errors, unsupported controls, timeout/disconnect races, and address/credential handling. Exercise an actual device separately and record the exact tested model/firmware.

Potential extensions are authenticated OpenWrt/UniFi diagnostics and configuration, a Home Assistant WebSocket registry/event adapter for areas/device relationships and push updates, direct MQTT adapters, a mobile Google Home SDK companion, and a separately validated cross-protocol audio bridge. They are extension points, not implemented features of 0.5.1.

## Verification

Run `swift test --disable-sandbox` and `UNIVERSAL=1 ./Scripts/build-app.sh`. Some managed command sandboxes block the system AAC encoder or release `dsymutil`; rerun with normal macOS access without altering source when that environmental restriction is confirmed. The physical Cast test remains opt-in because it takes over the selected receiver.

`Scripts/mock-home-hub.py` is a loopback-only synthetic REST fixture for repeatable native UI checks. Its name/token/entities are explicitly marked as demo data. It does not substitute for physical integration acceptance or a genuine Home Assistant installation.
