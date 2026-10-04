import HomeCore
import SwiftUI

struct AddHomeDeviceSheet: View {
    let home: HomeModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var room = ""
    @State private var kind: HomeDeviceKind = .router
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add a device").font(.title2.weight(.semibold))
            Text("Save the local management address of a router, Wi-Fi extender, or another home device.").foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name, prompt: Text("Living room router"))
                Picker("Type", selection: $kind) { ForEach(HomeDeviceKind.allCases) { Text($0.title).tag($0) } }
                TextField("Management address", text: $address, prompt: Text("http://192.168.1.1"))
                TextField("Room", text: $room, prompt: Text("Optional"))
            }
            Text("Use the device's actual IP address or .local hostname. Router and extender addresses can differ. Login and configuration happen in the device's management page in Safari.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red).accessibilityLabel(error) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add device") {
                    do { try home.addDevice(name: name, kind: kind, address: address, room: room); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || address.isEmpty)
            }
        }.padding(28).frame(width: 510)
    }
}

struct HomeBridgeSheet: View {
    @Bindable var home: HomeModel
    let suggestedURL: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    @State private var token = ""
    @State private var connectionError: String?
    @State private var task: Task<Void, Never>?

    init(home: HomeModel, suggestedURL: URL?) {
        self.home = home; self.suggestedURL = suggestedURL
        // An intentional one-time seed for this connection form; later changes belong to the user.
        _address = State(initialValue: suggestedURL?.absoluteString ?? home.settings.bridge?.url.absoluteString ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connect Home Assistant").font(.title2.weight(.semibold))
            Text("Bring devices from your existing Home Assistant server into Home Manager. Pair device integrations in Home Assistant first.").foregroundStyle(.secondary)
            Form {
                TextField("Server address", text: $address, prompt: Text("http://homeassistant.local:8123"))
                SecureField("Long-lived access token", text: $token)
            }.disabled(home.isConnecting)
            VStack(alignment: .leading, spacing: 8) {
                Text("In Home Assistant, open your profile → Security → Long-lived access tokens, then create a token for Home Manager.").font(.callout)
                Text("The token is stored in macOS Keychain. Use HTTPS for a remote server; local HTTP is available for private LAN addresses.").font(.caption).foregroundStyle(.secondary)
                if let url = try? HomeEndpointPolicy.address(address) {
                    Button("Open Home Assistant profile") { home.open(url.appendingPathComponent("profile/security")) }
                }
            }
            if let connectionError { Text(connectionError).font(.callout).foregroundStyle(.red) }
            HStack {
                if home.isConnecting { ProgressView().controlSize(.small); Text("Checking connection…").font(.caption) }
                Spacer()
                Button("Cancel", role: .cancel) { task?.cancel(); home.cancelConnect(); token = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") {
                    connectionError = nil
                    let enteredToken = token
                    task = Task {
                        if await home.connect(address: address, token: enteredToken) { token = ""; dismiss() }
                        else if !Task.isCancelled { connectionError = home.errorMessage; home.errorMessage = nil }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(home.isConnecting || address.isEmpty || token.isEmpty)
            }
        }
        .padding(28).frame(width: 550)
        .onDisappear { task?.cancel(); home.cancelConnect(); token = "" }
    }
}

struct HomeDeviceSheet: View {
    @Bindable var home: HomeModel
    let device: HomeDevice
    @Environment(\.dismiss) private var dismiss
    @State private var room: String
    @State private var favorite: Bool
    @State private var displayName: String

    init(home: HomeModel, device: HomeDevice) {
        self.home = home; self.device = device
        let annotation = home.annotation(device.id)
        // Editing owns a snapshot until Save is pressed.
        _room = State(initialValue: annotation.room); _favorite = State(initialValue: annotation.isFavorite)
        _displayName = State(initialValue: annotation.displayName ?? "")
    }

    var body: some View {
        let entity = home.entity(for: device)
        VStack(alignment: .leading, spacing: 20) {
            Label(home.displayName(for: device), systemImage: device.kind.symbol).font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LabeledContent("Type", value: device.kind.title)
                    LabeledContent("Connection", value: device.connectionSummary)
                    LabeledContent("State", value: entity.map { home.bridgeConnected ? $0.displayState : "Last known: \($0.displayState)" } ?? device.state)
                    if !device.model.isEmpty { LabeledContent("Model / entity", value: device.model).textSelection(.enabled) }
                    if let host = device.host { LabeledContent("Address", value: host).textSelection(.enabled) }
                    Text(device.controlNote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let entity {
                        entityControls(entity)
                    }
                    if let url = device.managementURL {
                        Button(device.source == .homeAssistant ? "Open Home Assistant dashboard" : "Open management page in Safari") { home.open(url) }
                        Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Divider()
                    Form {
                        TextField("Display name", text: $displayName, prompt: Text(device.name))
                        LabeledContent("Device name", value: device.name).textSelection(.enabled)
                        TextField("Room", text: $room, prompt: Text("Assign a room"))
                        Toggle("Favourite", isOn: $favorite)
                    }
                    HStack {
                        Text("Names, rooms, and favourites are saved on this Mac. Leave the display name blank to use the device name.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Use device name") { displayName = "" }.disabled(displayName.isEmpty)
                    }
                }
            }.frame(maxHeight: 450)
            HStack {
                if device.source == .manual {
                    Button("Remove saved device", role: .destructive) { home.removeSavedDevice(device.id); dismiss() }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { home.saveAnnotation(device.id, room: room, favorite: favorite, displayName: displayName); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 570)
    }

    private func entityControls(_ entity: HomeEntity) -> some View {
        let actions = HomeControls.actions(for: entity, services: home.services)
        let adjustments = HomeControls.adjustments(for: entity, services: home.services)
        let busy = home.busyEntities.contains(entity.id)
        return VStack(alignment: .leading, spacing: 16) {
            if !actions.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack { ForEach(actions) { action in Button(action.title) { Task { await home.perform(.action(action), entityID: entity.id) } } } }
                    VStack(alignment: .leading) { ForEach(actions) { action in Button(action.title) { Task { await home.perform(.action(action), entityID: entity.id) } } } }
                }
            }
            ForEach(adjustments) { adjustment in
                HomeAdjustmentView(adjustment: adjustment) { value in
                    Task { await home.perform(.adjust(adjustment.kind, value), entityID: entity.id) }
                }
            }
            if actions.isEmpty && adjustments.isEmpty {
                Text("State is available here. Further controls and device settings are in Home Assistant.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !home.bridgeConnected { Text(home.bridgeMessage).font(.caption).foregroundStyle(.secondary) }
        }.disabled(!home.bridgeConnected || busy)
    }
}

private struct HomeAdjustmentView: View {
    let adjustment: HomeAdjustment
    let apply: (Double) -> Void
    @State private var value: Double
    @State private var editing = false
    init(adjustment: HomeAdjustment, apply: @escaping (Double) -> Void) {
        self.adjustment = adjustment; self.apply = apply
        _value = State(initialValue: min(max(adjustment.value, adjustment.range.lowerBound), adjustment.range.upperBound))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(adjustment.title).font(.headline)
                Spacer()
                Text("\(value.formatted(.number.precision(.fractionLength(0...1))))\(adjustment.unit)").monospacedDigit()
            }
            Slider(value: $value, in: adjustment.range, step: adjustment.step) { editing = $0 }
                .accessibilityLabel(adjustment.title)
            Button("Apply \(adjustment.title.lowercased())") { apply(value) }
        }
        .onChange(of: adjustment.value) {
            if !editing { value = min(max(adjustment.value, adjustment.range.lowerBound), adjustment.range.upperBound) }
        }
    }
}
