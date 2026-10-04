# Device support and setup

Research checked against primary documentation on 3 October 2026. Home Manager 0.5.0 is an unreleased development expansion of Home Speaker, with support determined by protocols and reported capabilities.

## Supported paths

| Device / ecosystem | Discovery / connection | What this code implements | Required setup / limits |
| --- | --- | --- | --- |
| Google Home / Nest / Chromecast and third-party Cast receivers, including Xiaomi L09G | Direct `_googlecast._tcp` | Existing receiver status, playback, volume, and Mac audio capture/streaming | Set up the receiver first; one selected receiver at a time. Display/TV receiver discovery does not establish compatibility with every receiver app. |
| Lights, switches, outlets, and helpers | Home Assistant REST | On/off; brightness for lights that advertise a dimmable colour mode | The device must be integrated in Home Assistant and the service must exist. |
| Fans, thermostats, blinds/covers, vacuums, media players | Home Assistant REST | Advertised fan power/speed, supported target temperature, open/close/stop covers, vacuum start/pause/stop/dock, media play/pause/stop/volume | Entity feature flags and the server's service catalog gate each control. |
| Sensors, trackers, cameras, locks, alarms, and unimplemented entity domains | Home Assistant REST | Observed state, local room/favourite assignments, dashboard access | Camera streaming, lock/unlock, alarm actions, and arbitrary service execution are not implemented. Use the authenticated hub dashboard for additional settings. |
| Scenes and scripts | Home Assistant REST | Run the configured scene/script | Its actions are defined by the owner in Home Assistant. Automations expose on/off when services exist; no native automation editor. |
| Huawei routers and extenders | Gateway, advertised HTTP(S)/UPnP, or manually saved actual address | Inventory, room/favourite assignment, Safari management-page access | Full router settings stay in the firmware's management page or AI Life. Exact models differ. Supported Huawei LTE integrations can additionally expose sensors/switches through Home Assistant. |
| Xiaomi routers and extenders | Same network path; compatible Home Assistant integrations where configured | Inventory and actual web management links; hub entity controls when supported | A repeater is not automatically assigned the router's default IP. Some models use Mi Home rather than a web admin page. |
| OpenWrt, TP-Link, ASUS, NETGEAR, UniFi and other network equipment | Gateway, Bonjour/UPnP, or saved management address | Protocol-based inventory and management-page links | No native universal firmware/SSID/firewall writer. OpenWrt/UniFi API adapters require separate credentials, firmware/API validation, and implementation. |
| Xiaomi smart devices | User-configured Home Assistant integration | Controls for resulting supported entity domains | Xiaomi's official `ha_xiaomi_home` and HA's `xiaomi_miio` have different compatibility/authentication requirements. This app does not implement Xiaomi account login or extract tokens. |
| Matter / HomeKit accessories | `_matter._tcp`, `_matterc._udp`, `_hap._tcp` inventory | Advertised service discovery; control through existing compatible hub integrations | Commission/pair with an appropriate controller first. Seeing an advertisement is not authenticated control. |
| AirPlay receivers / IPP printers / generic HTTP services | Bonjour inventory | Service details, where relevant an advertised management URL | No new AirPlay sender or printer driver is bundled. |
| Google Home account and routines | Safari | Open `home.google.com` and automations | Google's official Home SDKs target Android/iOS. Account sync and full device setup are not native macOS features of this release. |

## Router and extender workflow

1. Open **Network**. The gateway tile uses the route reported by macOS; it is not assigned a manufacturer or assumed to be reachable.
2. Open **Details & settings → Open management page in Safari**. For UPnP devices, the link comes from a same-host `presentationURL`; the XML description endpoint is not presented as an admin page.
3. If the router/extender is missing, find its actual address from the manufacturer's instructions or the router's connected-client list. Use **Add device**, enter a name, choose **Router** or **Extender / access point**, enter `http://<private-IP>` or an HTTPS/.local management address, optionally enter a room, and choose **Add device**.
4. Log into the device itself in Safari. The native app does not store router passwords or apply network configuration changes.
5. For an extender without a web management page, use its manufacturer's supported phone application. Its presence in this inventory does not add an API it does not have.

Huawei documents web management and AI Life for supported router/extender models, and directs users to the nameplate/actual IP. Xiaomi documents web setup for the AC1200 using its default `192.168.31.1`/`router.miwifi.com` address. Those defaults are reference information, not targets hardcoded into discovery. [Huawei configuration](https://consumer.huawei.com/ca/support/content/en-us15806368/), [Xiaomi AC1200 setup](https://www.mi.com/global/support/faq/details/KA-226613/).

## Home Assistant connection

Configure the device integration in your Home Assistant instance first, then create a long-lived token in **Profile → Security**. Connect with the root server URL in **Connections → Connect Home Assistant**. Home Manager reads `/api/states` and `/api/services`; actions call `/api/services/<domain>/<service>` with an explicit `entity_id`. It never uses a POST to `/api/states` as a physical-device command. Home Assistant documents that a state write changes its representation rather than the actual device. [REST API documentation](https://developers.home-assistant.io/docs/api/rest/).

The dashboard counts **hub entities**, not physical devices. One physical appliance can expose many entities. Cast and a hub's media entity are kept separate because their relationship cannot be inferred safely from names. Rooms here are local annotations, independent of the hub's area registry.

## Discovery and connection limits

- Local discovery uses Bonjour plus a bounded IPv4 SSDP M-SEARCH. It does not enumerate every client, sweep ports, capture traffic, or prove internet/WAN status. Multicast filters, VLANs, client isolation, or permission denial can hide devices.
- Bonjour listens for additions/removals and refreshes every 60 seconds. SSDP entries expire after their advertised lifetime, capped at 120 seconds. A saved address is labelled **Saved address**; an imported entity after connection loss is labelled **Last known** and its controls are disabled.
- HTTP API access is restricted to private/loopback/link-local IPs and `.local` hostnames. Remote endpoints require HTTPS. HTTPS uses normal certificate validation; install a trusted certificate rather than bypassing validation. Authenticated requests do not follow redirects.
- There is no bundled Home Assistant server, MQTT broker, Zigbee radio, Z-Wave radio, Thread border router, or native Matter commissioner. These must be provided by the relevant integration/controller.

## Primary references and open-source research

- [Google Home APIs](https://developers.home.google.com/apis) and [iOS setup](https://developers.home.google.com/apis/ios/get-started): current official platform paths.
- [Home Assistant Core](https://github.com/home-assistant/core), [REST API](https://developers.home-assistant.io/docs/api/rest/), and [instance discovery](https://developers.home-assistant.io/docs/api/instance_discovery/): state/service semantics and Bonjour registration. The advertised port is used, rather than assuming 8123.
- [Home Assistant feature definitions: fan](https://github.com/home-assistant/core/blob/dev/homeassistant/components/fan/const.py), [cover](https://github.com/home-assistant/core/blob/dev/homeassistant/components/cover/const.py), [climate](https://github.com/home-assistant/core/blob/dev/homeassistant/components/climate/const.py), [vacuum](https://github.com/home-assistant/core/blob/dev/homeassistant/components/vacuum/const.py), [media player](https://github.com/home-assistant/core/blob/dev/homeassistant/components/media_player/const.py): feature-mask references for the implemented controls.
- [Home Assistant scene state](https://github.com/home-assistant/core/blob/dev/homeassistant/components/scene/__init__.py): a scene has no activation timestamp before its first run; `unknown` does not disable its Run action, while `unavailable` does.
- [Xiaomi's official Home Assistant integration](https://github.com/XiaoMi/ha_xiaomi_home) and [HA Xiaomi miio documentation](https://www.home-assistant.io/integrations/xiaomi_miio/): model-specific integration routes.
- [HA Huawei LTE](https://www.home-assistant.io/integrations/huawei_lte/) and [UPnP/IGD](https://www.home-assistant.io/integrations/upnp/): authenticated router integrations and network statistics where the hardware supports them.
- [PyChromecast](https://github.com/home-assistant-libs/pychromecast): reference for the existing direct Cast path.

These projects were read for interoperability research. Their code, logos, and runtime dependencies are not bundled or copied into Home Manager.
