# Home Manager 0.5.0 — development

**Status: unreleased.** This source expansion turns the Home Speaker project into a macOS home-management foundation.

- New native sidebar destinations for Your home, Favourites, Network, Music & speakers, Connections, and locally assigned rooms.
- Search, persistent manual device management addresses, room assignments, and favourites.
- Bonjour discovery for home hubs, HTTP(S), HomeKit, Matter, AirPlay, and IPP services; bounded IPv4 SSDP discovery and safe root-device descriptions; current macOS gateway entry.
- Home Assistant REST integration with Keychain token storage, state/service reads, polling, typed capability-aware device controls, reconnect/disconnect, and last-known state handling.
- Existing direct Cast/Apple Music/system audio features remain in Music & speakers. Navigating away no longer owns the audio lifecycle.
- Safari access for device management, Google Home/automations, hub integration setup, and model-specific Huawei/Xiaomi/Matter documentation.
- Shared `HomeCore` Swift library and additional tests for protocols, control capabilities, credential/persistence boundaries, HTTP redirects, and connection replacement/recovery.

The build output is `dist/HomeManager.app`; source executable and bundle ID retain their existing identifiers. Version 0.4.2 downloads remain the earlier speaker app. No 0.5.0 public release, notarization, or broad physical-device certification is claimed.

Home Assistant must already be set up for its device controls. Routers/extenders use actual management pages; native universal router configuration, Google account device sync, Matter commissioning, camera streaming, and a new automation editor are not implemented. See [device support](DEVICE-SUPPORT.md) for the complete scope and [architecture](HOME-ARCHITECTURE.md) for extension paths.
