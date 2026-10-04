# Home Manager 0.5.1 local verification

Date: 4 October 2026. Local development version 0.5.1, build 11. This report separates source/automated evidence, observed receiver behaviour, and audible acceptance.

## Source and branch

- Branch: `shudu/multi-device-casting`.
- Intentional dependency: the accepted whole-home implementation was preserved in local commit `505e831` on `shudu/whole-home-management` before this feature branch was created. That baseline follows fetched integration commit `e671354`. The new feature does not discard the working home inventory/hub implementation.
- No push, GitHub PR, hosted CI run, Developer ID signing, notarisation, or public release was performed for 0.5.1.
- The displayed product is Home Manager; the source target/executable and bundle ID remain `HomeSpeaker` / `za.shudu.homespeaker`.

## Automated evidence

Command:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/home-manager-clang-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/home-manager-swift-cache \
swift test --disable-sandbox --scratch-path .build
```

Final run: **51 tests executed, 50 passed, 1 skipped, 0 failures**. The executable test target ran 37 tests with the physical receiver opt-in case skipped; HomeCore ran 14 passing tests. The existing opt-in test requires `HOME_SPEAKER_TEST_HOST` and deliberately takes over that receiver, so it was not implicitly enabled in the suite. The native group check below is separate.

Coverage added for this feature:

- Adding a second independent receiver retains the first connection. The original replacement behaviour was reproduced as an assertion failure before implementation.
- Two receiver fixtures get the same content URL, autoplay false and the same start position. No receiver starts through the coordinator until all are connected/prepared; confirmation requires all expected streams to be Playing.
- Master/per-device volume, shared pause/cancel, exclusive group selection, stale connection generations, receiver takeover/failure, and unexpected positive playback speed.
- Timing extrapolation to a shared monotonic instant, fresh sample requirements, normal speed, reported live-seek capabilities/range intersection, three distinct sustained-drift rounds, correction cooldown, and stale/foreign/paused/buffering media rejection.
- Real Cast-format JSON numbers and partial timing updates, speed transitions, and removed/ended live ranges.
- Two separate ephemeral HTTP sessions concurrently fetch identical AAC fragment bytes from one live server. Bounded multi-device history preserves the startup beginning and stays at sixty-four segments during long sessions. Existing single-receiver short-window, native AAC decoding/stereo, overload, silent startup, track identity and capture cancellation tests remain passing.
- The real group's initial new-media Idle sequence was reproduced as a failing test and fixed. A zero-rate stopped media clock in Playing state was also reproduced and fixed without weakening rejection of actual positive slow/fast playback.
- Whole-home endpoint policy, authentication, controls, discovery parsing, saved settings, offline/reconnect and stale-response regressions remain passing.

Fixtures prove sender coordination and digital audio delivery; they do not simulate physical speaker output clocks or TV DSP delay.

## Build and artifact

`UNIVERSAL=1 ./Scripts/build-app.sh` completed successfully. `dist/HomeManager.app` contains `x86_64` and `arm64`; both Mach-O slices report minimum macOS 14.4. `codesign --verify --deep --strict` passed for the ad-hoc development signature. The plist is valid and contains version 0.5.1/build 11. `git diff --check` passed.

The build has the already documented legacy desktop Keychain compatibility deprecation warnings and an Xcode toolchain Intel-target warning. These do not establish Intel runtime acceptance; Intel execution was not performed on this Apple silicon host.

## Native app and real local devices

- Launched the rebuilt app from `dist/HomeManager.app`. The existing `/Applications/Home Speaker.app` was preserved; only the development copy was quit/replaced during rebuilds.
- Observed **Office Speaker** (Mi Smart Speaker), **Home group**, and **Home Speakers** (the latter two model `Google Cast Group`). Connected to Office Speaker without launching media, then selected Home group and confirmed exclusive replacement and group connection.
- After the owner powered the TV on, observed **Samsung AU7000 50 TV**, model **UA50AU7000KXXA**, in AirPlay Bonjour and UPnP inventory. Its AirPlay details explicitly identified the protocol. No Samsung Cast endpoint was observed. The rebuilt Music view showed its compatibility guidance under **Other TVs & media devices**.
- On the final app, cast **All Mac audio** to **Home group**. The actual group requested an AAC media fragment, progressed through Buffering, and reached **Playing · 1× speed**. After the transient startup clock stops, normal Playing at rate 1 was logged at 10:45:21 local time; playback remained active until the deliberate Stop at approximately 10:46:06, about forty-five seconds later.
- Selected **Stop casting**. Receiver Idle was acknowledged; the Core Audio lifecycle logged **Capture released; local playback restored** at 10:47:36. The UI returned to Connected with Cast Mac audio enabled and no active capture. The development app was left open on Music & speakers.
- No changes were made to TV pairing/account settings, group membership, router settings, saved rooms, or favourites. No demo hub or synthetic UI data was added during this feature check.

The local UPnP scan intermittently reported multicast `No route to host`; Bonjour Cast discovery and TCP group playback still worked. This is recorded as observed discovery behaviour, not a claim that every LAN service was reachable.

## Runtime limits and outstanding acceptance

The final Core Audio capture setup and release on this Mac each took about ninety seconds. These operations run outside the UI thread; the interface remained responsive, and cleanup eventually completed. This feature keeps the existing capture engine; the cause of that slow OS/audio lifecycle was not established here and needs a separate runtime diagnosis before a wider release. Current default sound output was read afterward as MacBook Air Speakers; no output setting was changed.

The real check confirms receiver acceptance, normal reported rate, stable group playback state and eventual resource release. It does **not** prove non-silent Apple Music capture, group member count, audible output quality, echo-free timing, or acoustic TV/speaker alignment. No audible acceptance was reported by the owner for this feature.

The Samsung's observed AirPlay/UPnP endpoint cannot join this Cast session by itself. The exact requested TV-plus-speaker pair remains unverified and requires a group-compatible Cast receiver connected to the TV, or a separately implemented and validated cross-protocol bridge. Direct independent two-receiver coordination was verified with receiver-boundary fixtures and parallel real HTTP clients, not with two physical independent Cast receivers in this home.

See [multi-device setup and timing limits](MULTI-DEVICE-CASTING.md). This feature sends Mac audio; it does not add video/screen mirroring or cast audio generated by apps running inside the TV.
