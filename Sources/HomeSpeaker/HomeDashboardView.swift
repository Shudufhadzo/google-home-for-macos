import HomeCore
import SwiftUI

private enum HomeDestination: Hashable {
    case overview, favorites, network, music, connections, room(String)
    var title: String {
        switch self {
        case .overview: return "Your home"
        case .favorites: return "Favourites"
        case .network: return "Network"
        case .music: return "Music & speakers"
        case .connections: return "Connections"
        case .room(let name): return name
        }
    }
}

private enum HomeSheet: Identifiable {
    case add, bridge(URL?), device(HomeDevice)
    var id: String {
        switch self {
        case .add: return "add"
        case .bridge: return "bridge"
        case .device(let device): return device.id
        }
    }
}

struct HomeDashboardView: View {
    @Bindable var home: HomeModel
    @ObservedObject var speaker: SpeakerModel
    @State private var destination: HomeDestination? = .overview
    @State private var search = ""
    @State private var sheet: HomeSheet?

    var body: some View {
        NavigationSplitView {
            List(selection: $destination) {
                Section("Home Manager") {
                    NavigationLink(value: HomeDestination.overview) { Label("Your home", systemImage: "house") }
                    NavigationLink(value: HomeDestination.favorites) { Label("Favourites", systemImage: "star") }
                    NavigationLink(value: HomeDestination.network) { Label("Network", systemImage: "wifi.router") }
                    NavigationLink(value: HomeDestination.music) { Label("Music & speakers", systemImage: "hifispeaker") }
                    NavigationLink(value: HomeDestination.connections) { Label("Connections", systemImage: "point.3.connected.trianglepath.dotted") }
                }
                if !home.rooms.isEmpty {
                    Section("Rooms") {
                        ForEach(home.rooms, id: \.self) { room in
                            NavigationLink(value: HomeDestination.room(room)) { Label(room, systemImage: "door.left.hand.open") }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(home.bridgeConnected ? "Home hub connected" : "Local discovery", systemImage: home.bridgeConnected ? "checkmark.circle" : "network")
                        .font(.caption)
                    Text("Home Speaker is now part of your whole home.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            Group {
                switch destination ?? .overview {
                case .music: ContentView(model: speaker, home: home)
                case .connections: connections
                default: inventory
                }
            }
            .navigationTitle((destination ?? .overview).title)
            .toolbar {
                ToolbarItemGroup {
                    Button { sheet = .add } label: { Label("Add device", systemImage: "plus") }.help("Add a router, extender, or device by its local management address")
                    Button { speaker.scanAgain(); home.scanAgain() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Discover devices and refresh your home hub")
                }
            }
        }
        .searchable(text: $search, prompt: "Find a device, room, or type")
        .sheet(item: $sheet) { item in
            switch item {
            case .add: AddHomeDeviceSheet(home: home)
            case .bridge(let url): HomeBridgeSheet(home: home, suggestedURL: url)
            case .device(let device): HomeDeviceSheet(home: home, device: device)
            }
        }
        .alert("Home Manager", isPresented: Binding(get: { home.errorMessage != nil }, set: { if !$0 { home.errorMessage = nil } })) {
            Button("OK", role: .cancel) { home.errorMessage = nil }
        } message: { Text(home.errorMessage ?? "") }
    }

    private var inventory: some View {
        let all = home.devices(cast: speaker.devices)
        let visible = all.filter { device in
            let annotation = home.annotation(device.id)
            let matchesDestination: Bool
            switch destination ?? .overview {
            case .favorites: matchesDestination = annotation.isFavorite
            case .room(let room): matchesDestination = annotation.room == room
            case .network: matchesDestination = device.source != .homeAssistant && device.source != .cast
            default: matchesDestination = true
            }
            let text = [home.displayName(for: device), device.name, device.model, device.kind.title, device.connectionSummary, device.host ?? "", annotation.room].joined(separator: " ")
            return matchesDestination && (search.isEmpty || text.localizedCaseInsensitiveContains(search))
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                inventoryHeader(all: all)
                if destination == .network { networkGuidance }
                if visible.isEmpty {
                    ContentUnavailableView {
                        Label(search.isEmpty ? emptyTitle : "No matching devices", systemImage: search.isEmpty ? "house" : "magnifyingglass")
                    } description: {
                        Text(search.isEmpty ? "Discover devices on this network, add a management address, or connect Home Assistant. Open a device to assign its room." : "Try another device name, room, or type.")
                    } actions: {
                        if search.isEmpty {
                            Button("Add device") { sheet = .add }
                            Button("Connect home hub") { sheet = .bridge(nil) }
                        }
                    }.frame(minHeight: 280)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 245, maximum: 380), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(visible) { device in
                            HomeDeviceCard(device: device, annotation: home.annotation(device.id),
                                           entity: home.entity(for: device), services: home.services,
                                           connected: home.bridgeConnected, busy: home.entity(for: device).map { home.busyEntities.contains($0.id) } ?? false,
                                           select: { select(device) }, inspect: { sheet = .device(device) }, favorite: { home.toggleFavorite(device.id) },
                                           command: { command in
                                if let entity = home.entity(for: device) { Task { await home.perform(command, entityID: entity.id) } }
                            })
                        }
                    }
                }
                discoveryStatus
            }
            .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyTitle: String {
        destination == .favorites ? "Your favourites will appear here" : "Make room for your devices"
    }

    private func inventoryHeader(all: [HomeDevice]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text((destination ?? .overview).title).font(.largeTitle.weight(.bold))
                Text(destination == .network ? "Routers, extenders, hubs, and services on your local network." : "Keep your devices, rooms, and everyday controls together.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                metric("Cast devices", count: speaker.devices.count, symbol: "hifispeaker")
                metric("Network entries", count: all.filter { $0.source != .cast && $0.source != .homeAssistant }.count, symbol: "wifi.router")
                metric("Hub entities", count: home.entities.count, symbol: "switch.2")
                Spacer(minLength: 0)
                if home.isScanning { ProgressView().controlSize(.small).accessibilityLabel("Discovering devices") }
            }
            if home.settings.bridge == nil {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "house.and.flag").font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bring the rest of your home together").font(.headline)
                        Text("Connect Home Assistant for compatible lights, plugs, fans, climate, blinds, vacuums, sensors, and scenes.")
                            .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Connect home hub") { sheet = .bridge(nil) }.buttonStyle(.borderedProminent)
                }
                .padding(18).background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            } else if !home.bridgeConnected {
                Label(home.bridgeMessage, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.secondary)
                Button("Reconnect home hub") { sheet = .bridge(home.settings.bridge?.url) }
            }
        }
    }

    private func metric(_ label: String, count: Int, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(count, format: .number).font(.title3.weight(.semibold)).monospacedDigit()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }

    private var networkGuidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Configure your network").font(.headline)
            Text("Open a router or extender's management page in Safari to change its settings. If a device does not advertise itself, add the address shown in its manual or your router's client list.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Some extenders use only their manufacturer's phone app. A saved address records a device; it does not confirm that it is online.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private var discoveryStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(home.networkMessage, systemImage: "network").font(.caption).foregroundStyle(.secondary)
            if let interface = home.networkInterface { Text("Mac network interface: \(interface)").font(.caption2).foregroundStyle(.tertiary) }
            if home.settings.bridge != nil {
                Text(home.bridgeMessage).font(.caption).foregroundStyle(.secondary)
                if let date = home.lastRefresh { Text("Last hub update: \(date.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
    }

    private func select(_ device: HomeDevice) {
        if device.source == .cast {
            if let cast = speaker.devices.first(where: { "cast:\($0.id)" == device.id }) { speaker.connect(to: cast) }
            destination = .music
        } else if device.capabilities.contains(.airPlay) {
            if !speaker.isCastingMacAudio && !speaker.isRestoringAudio { speaker.includeAirPlay = true }
            destination = .music
        } else if device.kind == .bridge && device.source == .bonjour { sheet = .bridge(device.managementURL) }
        else { sheet = .device(device) }
    }

    private var connections: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Connections").font(.largeTitle.weight(.bold))
                Text("Choose how your home devices connect.").foregroundStyle(.secondary)
                connectionPanel("Google Cast", symbol: "hifispeaker", detail: "Direct discovery, playback, volume, and Mac audio on compatible Cast receivers. \(speaker.devices.count) found.") {
                    Button("Music & speakers") { destination = .music }
                }
                connectionPanel("Home Assistant", symbol: "house", detail: home.bridgeMessage) {
                    if let bridge = home.settings.bridge {
                        Text(bridge.url.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Button("Open dashboard") { home.open(bridge.url) }
                            Button("Device integrations") { home.open(bridge.url.appendingPathComponent("config/integrations")) }
                            Button("Reconnect") { sheet = .bridge(bridge.url) }
                            Button(home.isDisconnecting ? "Disconnecting…" : "Disconnect", role: .destructive) { Task { await home.disconnectBridge() } }
                                .disabled(home.isDisconnecting || home.isConnecting)
                        }
                    } else {
                        Button("Connect Home Assistant") { sheet = .bridge(nil) }.buttonStyle(.borderedProminent)
                        Button("Home Assistant setup guide") { home.open(URL(string: "https://www.home-assistant.io/installation/")!) }
                    }
                }
                connectionPanel("Google Home", symbol: "house.and.flag", detail: "Open your Google Home account and automations in Safari. Initial setup and full device settings use the Google Home phone app.") {
                    HStack {
                        Button("Google Home") { home.open(URL(string: "https://home.google.com/")!) }
                        Button("Automations") { home.open(URL(string: "https://home.google.com/automations")!) }
                    }
                }
                connectionPanel("Routers & extenders", symbol: "wifi.router", detail: "Use the device's web management page or manufacturer app. Support depends on the exact model and firmware.") {
                    HStack {
                        Button("Add management address") { sheet = .add }
                        Button("Huawei guide") { home.open(URL(string: "https://consumer.huawei.com/ca/support/content/en-us15806368/")!) }
                        Button("Xiaomi router guide") { home.open(URL(string: "https://www.mi.com/global/support/faq/details/KA-226613/")!) }
                    }
                }
                connectionPanel("Matter, HomeKit & other ecosystems", symbol: "point.3.connected.trianglepath.dotted", detail: "Discovery identifies advertised accessories. Commission and pair them with a compatible controller; Home Assistant can expose supported integrations here. Native Matter commissioning and Google account sync are not yet included.") {
                    HStack {
                        Button("Matter setup") { home.open(URL(string: "https://www.home-assistant.io/integrations/matter/")!) }
                        Button("Xiaomi integration") { home.open(URL(string: "https://github.com/XiaoMi/ha_xiaomi_home")!) }
                        Button("Huawei LTE integration") { home.open(URL(string: "https://www.home-assistant.io/integrations/huawei_lte/")!) }
                    }
                }
                discoveryStatus
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func connectionPanel<Actions: View>(_ title: String, symbol: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            actions()
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct HomeDeviceCard: View {
    let device: HomeDevice
    let annotation: DeviceAnnotation
    let entity: HomeEntity?
    let services: HomeServiceCatalog
    let connected: Bool
    let busy: Bool
    let select: () -> Void
    let inspect: () -> Void
    let favorite: () -> Void
    let command: (HomeCommand) -> Void
    private var displayName: String { annotation.displayName ?? device.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Button(action: inspect) {
                    HStack(spacing: 12) {
                        Image(systemName: device.kind.symbol).font(.title2).foregroundStyle(.tint).frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(displayName).font(.headline).lineLimit(2)
                            Text(annotation.room.isEmpty ? device.kind.title : annotation.room).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Open \(displayName)")
                Button(action: favorite) { Image(systemName: annotation.isFavorite ? "star.fill" : "star") }
                    .buttonStyle(.plain).foregroundStyle(annotation.isFavorite ? Color.accentColor : .secondary)
                    .accessibilityLabel(annotation.isFavorite ? "Remove \(displayName) from favourites" : "Add \(displayName) to favourites")
                    .help(annotation.isFavorite ? "Remove favourite" : "Add favourite")
            }
            HStack {
                Text(device.state).font(.subheadline).lineLimit(1)
                Spacer()
                if busy { ProgressView().controlSize(.mini).accessibilityLabel("Sending command") }
            }
            Text(device.connectionSummary).font(.caption).foregroundStyle(.secondary)
            if let entity {
                let actions = HomeControls.actions(for: entity, services: services)
                if !actions.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack { ForEach(actions) { action in Button(action.title) { command(.action(action)) } } }
                        VStack(alignment: .leading) { ForEach(actions) { action in Button(action.title) { command(.action(action)) } } }
                    }.disabled(!connected || busy)
                } else { Button("Details", action: inspect) }
            } else {
                if device.source == .cast || device.kind == .bridge || device.capabilities.contains(.airPlay) {
                    HStack {
                        Button(device.source == .cast ? "Connect" : device.capabilities.contains(.airPlay) ? "Play via AirPlay" : "Connect hub", action: select)
                        Button("Details", action: inspect)
                    }
                } else { Button("Details & settings", action: inspect) }
            }
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 175, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.12)))
        .contextMenu { Button("Rename device…", action: inspect) }
    }
}
