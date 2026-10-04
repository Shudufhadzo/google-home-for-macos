# Home Manager 0.5.3 display names

Checked 4 October 2026. Local development build 13 on branch `shudu/device-display-names`.

## Scope and baseline

This feature intentionally depends on local commit `e39aeb1`, the accepted device-reconciliation and Cast/AirPlay implementation. The preceding changes were preserved on `shudu/unified-media-devices` before creating this distinct feature branch. Origin was fetched before branching; its integration branch remains the older published speaker baseline. No push, public release, notarisation, or installation over the published application was performed.

Device Details now offers **Display name**, retains the original **Device name**, and includes **Use device name** to clear a custom name. Inventory cards also expose **Rename device…** in their context menu. Display names are stored as optional local annotations and used in inventory sorting/search, accessibility labels, Cast cards, destination controls, Now Playing destination labels, and the discovered AirPlay list. macOS's native AirPlay picker uses the receiver's advertised name.

The original name is kept in discovery records so custom naming does not change reconciliation, connection identity, endpoints, source applications, or playback. Existing room/favourite edits preserve custom names. Clearing a name updates every known discovery alias so an expired service cannot resurrect an older name.

## Automated and build evidence

`swift test` ran **87 tests: 86 passed, 1 opt-in physical receiver test skipped, 0 failures**. This includes 60 HomeSpeaker tests and 27 HomeCore tests. New or extended cases cover:

- TV names surviving AirPlay/UPnP reconciliation, service expiry, refresh and model reload, then resetting across all aliases.
- Room/favourite edits retaining names; Home Assistant reconnects migrating them to the replacement bridge identity.
- Distinct Cast device/group annotations, displayed-name ordering, and unchanged advertised names, hosts and ports.
- Existing version-1 settings decoding without display names, saved-device identity/URL preservation, whitespace trimming and the 128-character name limit.

`./Scripts/build-app.sh` completed a native Apple silicon release build at `dist/HomeManager.app`; strict ad-hoc code-signature verification passed. The app reports 0.5.3/build 13. The existing desktop Keychain deprecation warnings remain. `git diff --check` passed.

## Native UI check

Launched the rebuilt development app and refreshed the actual home inventory. Opened **Samsung AU7000 50 TV**, entered the temporary display name **Living room TV**, and saved. The single reconciled TV card and its accessibility label updated immediately. Searching for **Living room TV** returned that device. After quitting and reopening Home Manager, the saved name still appeared on the TV card.

Opened its Details again, verified that **Device name** still showed **Samsung AU7000 50 TV**, then used **Use device name** and saved. The original name returned to the card. The temporary test name was removed; the device's blank room and non-favourite state were preserved. The app was left open on Your home.

These checks validate display-name editing and persistence. Playback was not restarted or taken over as part of this UI check; casting was already stopped when the development app was replaced.
