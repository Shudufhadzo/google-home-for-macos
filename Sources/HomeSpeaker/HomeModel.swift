import AppKit
import Foundation
import HomeCore
import Observation

@MainActor
@Observable
final class HomeModel {
    private(set) var settings: HomeSettings
    private(set) var networkDevices: [HomeDevice] = []
    private(set) var networkMessage = "Ready to discover your home."
    private(set) var networkInterface: String?
    private(set) var isScanning = false
    private(set) var entities: [HomeEntity] = []
    private(set) var services = HomeServiceCatalog(domains: [:])
    private(set) var bridgeConnected = false
    private(set) var isRefreshing = false
    private(set) var isConnecting = false
    private(set) var isDisconnecting = false
    private(set) var bridgeMessage = "Connect a home hub to control more devices."
    private(set) var lastRefresh: Date?
    private(set) var busyEntities: Set<String> = []
    var errorMessage: String?

    @ObservationIgnored private let persistence: any HomeSettingsPersisting
    @ObservationIgnored private let credentials: HomeCredentialWorker
    @ObservationIgnored private let clientFactory: (URL, String) throws -> any HomeAssistantConnecting
    @ObservationIgnored private var client: (any HomeAssistantConnecting)?
    @ObservationIgnored private let discovery = HomeNetworkDiscovery()
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var networkPolling: Task<Void, Never>?
    @ObservationIgnored private var restoration: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var connectAttempt = UUID()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var deviceAliases: [String: Set<String>] = [:]

    init(persistence: any HomeSettingsPersisting = HomeSettingsStore(),
         credentials: any HomeCredentialStoring = HomeCredentialStore(),
         clientFactory: @escaping (URL, String) throws -> any HomeAssistantConnecting = { try HomeAssistantClient(baseURL: $0, token: $1) }) {
        self.persistence = persistence; self.credentials = HomeCredentialWorker(credentials); self.clientFactory = clientFactory
        do { settings = try persistence.load() }
        catch { settings = HomeSettings(); errorMessage = "Saved home settings could not be read. \(error.localizedDescription)" }
        discovery.onUpdate = { [weak self] devices, message, interface, scanning in
            guard let self else { return }
            self.acceptNetworkDevices(devices); self.networkMessage = message
            self.networkInterface = interface; self.isScanning = scanning
        }
    }

    var rooms: [String] { Set(settings.annotations.values.map(\.room).filter { !$0.isEmpty }).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    func annotation(_ id: String) -> DeviceAnnotation {
        let ids = [id] + (deviceAliases[id] ?? []).subtracting([id]).sorted()
        let annotations = ids.compactMap { settings.annotations[$0] }
        return DeviceAnnotation(room: annotations.first(where: { !$0.room.isEmpty })?.room ?? "",
                                isFavorite: annotations.contains(where: \.isFavorite),
                                displayName: annotations.compactMap(\.displayName).first(where: { !$0.isEmpty }))
    }

    func displayName(for device: HomeDevice) -> String { annotation(device.id).displayName ?? device.name }
    func displayName(for device: CastDevice) -> String { annotation("cast:\(device.id)").displayName ?? device.name }

    /// Retain annotation aliases across service expiry and rescan, using protocol IDs only.
    func acceptNetworkDevices(_ devices: [HomeDevice]) {
        networkDevices = HomeDeviceReconciler.reconcile(devices)
        rememberAliases(networkDevices)
        var changed = false
        for device in networkDevices {
            let aliases = deviceAliases[device.id] ?? device.discoveryIDs
            guard aliases.contains(where: { settings.annotations[$0] != nil }) else { continue }
            let value = annotation(device.id)
            for alias in aliases where settings.annotations[alias] != value {
                settings.annotations[alias] = value; changed = true
            }
        }
        if changed { persist() }
    }

    private func rememberAliases(_ devices: [HomeDevice]) {
        for device in devices {
            var aliases = device.discoveryIDs
            for alias in device.discoveryIDs { aliases.formUnion(deviceAliases[alias] ?? []) }
            for alias in aliases { deviceAliases[alias] = aliases }
        }
    }
    func entity(for device: HomeDevice) -> HomeEntity? {
        guard let bridge = settings.bridge, device.source == .homeAssistant else { return nil }
        return entities.first { "ha:\(bridge.id.uuidString):\($0.id)" == device.id }
    }

    func devices(cast: [CastDevice]) -> [HomeDevice] {
        var result = networkDevices + settings.devices.map(\.device)
        result += cast.map { device in
            let tv = !device.model.localizedCaseInsensitiveContains("audio") &&
                ["TV", "Chromecast", "display", "Nest Hub"].contains { device.model.localizedCaseInsensitiveContains($0) }
            return HomeDevice(id: "cast:\(device.id)", name: device.name, kind: tv ? .television : .speaker, source: .cast,
                              model: device.model, host: device.host, state: "Discovered",
                              controlNote: "Connect in Music & speakers for playback, volume, and Mac audio casting.",
                              capabilities: device.isGroup ? [.castGroup] : [])
        }
        if let bridge = settings.bridge {
            result += entities.map {
                var device = $0.device(bridgeID: bridge.id, baseURL: bridge.url)
                if !bridgeConnected { device.state = "Last known: \(device.state)" }
                return device
            }
        }
        result = HomeDeviceReconciler.reconcile(result)
        rememberAliases(result)
        return result.sorted {
            let lhs = annotation($0.id).isFavorite, rhs = annotation($1.id).isFavorite
            if lhs != rhs { return lhs }
            return displayName(for: $0).localizedStandardCompare(displayName(for: $1)) == .orderedAscending
        }
    }

    func start() {
        guard !started else { return }; started = true
        discovery.scan()
        networkPolling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                guard let self else { return }; self.discovery.scan()
            }
        }
        if let bridge = settings.bridge {
            let run = connectionGeneration
            bridgeMessage = "Checking saved home hub connection…"
            restoration = Task { [weak self, credentials] in
                do {
                    guard let token = try await credentials.read(account: bridge.id.uuidString) else { throw HomeConnectionError.missingCredential }
                    guard !Task.isCancelled, let self, self.connectionGeneration == run, self.settings.bridge == bridge else { return }
                    self.client = try self.clientFactory(bridge.url, token)
                    self.beginPolling()
                } catch {
                    guard !Task.isCancelled, let self, self.connectionGeneration == run else { return }
                    self.bridgeMessage = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        started = false; connectAttempt = UUID(); connectionGeneration = UUID()
        polling?.cancel(); polling = nil; networkPolling?.cancel(); networkPolling = nil
        restoration?.cancel(); restoration = nil
        discovery.stop(); isScanning = false; isConnecting = false; isRefreshing = false
        client = nil; bridgeConnected = false; isDisconnecting = false; busyEntities.removeAll()
    }

    func scanAgain() { discovery.scan(); Task { await refresh() } }

    /// Validate the new connection before replacing the saved bridge or credential.
    func connect(address: String, token: String) async -> Bool {
        guard !isConnecting, !isDisconnecting else { return false }
        let attempt = UUID(); connectAttempt = attempt; isConnecting = true
        defer { if connectAttempt == attempt { isConnecting = false } }
        do {
            let url = try HomeEndpointPolicy.address(address)
            let candidate = try clientFactory(url, token)
            let snapshot = try await candidate.snapshot()
            guard !Task.isCancelled, connectAttempt == attempt else { return false }
            let previous = settings.bridge
            let bridge = HomeBridgeConfiguration(id: UUID(), url: url)
            // A fresh Keychain item makes replacement atomic from the old connection's perspective.
            try await credentials.save(token.trimmingCharacters(in: .whitespacesAndNewlines), account: bridge.id.uuidString)
            guard !Task.isCancelled, connectAttempt == attempt else {
                try? await credentials.remove(account: bridge.id.uuidString); return false
            }
            var next = settings; next.bridge = bridge
            do { try persistence.save(next) }
            catch { try? await credentials.remove(account: bridge.id.uuidString); throw error }
            restoration?.cancel(); restoration = nil
            polling?.cancel(); connectionGeneration = UUID(); busyEntities.removeAll(); isRefreshing = false
            settings = next; client = candidate
            apply(snapshot)
            if let previous {
                // Keep locally assigned rooms/favorites when reconnecting the same server.
                if previous.url == url {
                    for entity in snapshot.entities {
                        let oldID = "ha:\(previous.id.uuidString):\(entity.id)", newID = "ha:\(bridge.id.uuidString):\(entity.id)"
                        if let annotation = settings.annotations[oldID] { settings.annotations[newID] = annotation; settings.annotations.removeValue(forKey: oldID) }
                    }
                    persist()
                }
            }
            beginPolling(refreshImmediately: false)
            if let previous {
                do { try await credentials.remove(account: previous.id.uuidString) }
                catch { errorMessage = "The new connection is saved, but the previous Keychain item could not be removed. \(error.localizedDescription)" }
            }
            return true
        } catch {
            if connectAttempt == attempt { errorMessage = error.localizedDescription }
            return false
        }
    }

    func cancelConnect() { connectAttempt = UUID(); isConnecting = false }

    func disconnectBridge() async {
        guard let bridge = settings.bridge, !isConnecting, !isDisconnecting else { return }
        let run = connectionGeneration; isDisconnecting = true
        defer { if connectionGeneration == run { isDisconnecting = false } }
        do {
            // Delete the secret before clearing the visible configuration; failures remain actionable.
            try await credentials.remove(account: bridge.id.uuidString)
            guard !Task.isCancelled, connectionGeneration == run else { return }
            var next = settings; next.bridge = nil
            try persistence.save(next)
            polling?.cancel(); polling = nil; restoration?.cancel(); restoration = nil
            connectionGeneration = UUID(); connectAttempt = UUID()
            settings = next; client = nil; entities.removeAll(); services = .init(domains: [:])
            bridgeConnected = false; isRefreshing = false; isConnecting = false; isDisconnecting = false; lastRefresh = nil; busyEntities.removeAll()
            bridgeMessage = "Home Assistant disconnected."
        } catch { errorMessage = error.localizedDescription }
    }

    func refresh() async {
        guard let client, !isRefreshing else { return }
        let run = connectionGeneration; isRefreshing = true
        defer { if connectionGeneration == run { isRefreshing = false } }
        do {
            let snapshot = try await client.snapshot()
            guard !Task.isCancelled, connectionGeneration == run else { return }
            apply(snapshot)
        } catch {
            guard !Task.isCancelled, connectionGeneration == run else { return }
            bridgeConnected = false
            bridgeMessage = "Connection unavailable. \(error.localizedDescription)"
        }
    }

    func perform(_ command: HomeCommand, entityID: String) async {
        guard bridgeConnected, !isDisconnecting, let client, let entity = entities.first(where: { $0.id == entityID }),
              !busyEntities.contains(entityID) else { return }
        let run = connectionGeneration; busyEntities.insert(entityID)
        defer { if connectionGeneration == run { busyEntities.remove(entityID) } }
        do {
            try await client.perform(command, entity: entity, services: services)
            guard !Task.isCancelled, connectionGeneration == run else { return }
            // Read observed state after a service call; never invent a successful device state.
            await refresh()
        } catch {
            guard !Task.isCancelled, connectionGeneration == run else { return }
            errorMessage = error.localizedDescription
        }
    }

    func saveAnnotation(_ id: String, room: String, favorite: Bool, displayName: String? = nil) {
        let enteredName = displayName.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128)) }
        let savedName: String?
        if let enteredName { savedName = enteredName.isEmpty ? nil : enteredName }
        else { savedName = annotation(id).displayName }
        let annotation = DeviceAnnotation(room: String(room.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)),
                                          isFavorite: favorite, displayName: savedName)
        for alias in deviceAliases[id] ?? [id] { settings.annotations[alias] = annotation }
        persist()
    }
    func toggleFavorite(_ id: String) {
        let value = annotation(id); saveAnnotation(id, room: value.room, favorite: !value.isFavorite)
    }
    func addDevice(name: String, kind: HomeDeviceKind, address: String, room: String) throws {
        let url = try HomeEndpointPolicy.address(address, localOnly: true)
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
        guard !name.isEmpty else { throw HomeConnectionError.invalidValue }
        guard !settings.devices.contains(where: { $0.url == url }) else { throw SavedDeviceError.duplicate }
        let device = SavedHomeDevice(name: name, kind: kind, url: url)
        var next = settings; next.devices.append(device)
        next.annotations[device.device.id] = .init(room: String(room.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))
        try persistence.save(next); settings = next
    }
    func removeSavedDevice(_ id: String) {
        var next = settings
        next.devices.removeAll { $0.device.id == id }; next.annotations.removeValue(forKey: id)
        do { try persistence.save(next); settings = next } catch { errorMessage = error.localizedDescription }
    }
    func open(_ url: URL) {
        guard let safe = try? HomeEndpointPolicy.address(url.absoluteString) else { return }
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            errorMessage = "Safari is unavailable on this Mac."; return
        }
        NSWorkspace.shared.open([safe], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if let error { Task { @MainActor [weak self] in self?.errorMessage = "Could not open Safari. \(error.localizedDescription)" } }
        }
    }

    private func apply(_ snapshot: HomeSnapshot) {
        entities = snapshot.entities; services = snapshot.services
        bridgeConnected = true; lastRefresh = Date()
        bridgeMessage = "Connected · \(entities.count) entities · refreshed every 10 seconds"
    }
    private func persist() { do { try persistence.save(settings) } catch { errorMessage = error.localizedDescription } }
    private func beginPolling(refreshImmediately: Bool = true) {
        polling?.cancel()
        polling = Task { [weak self] in
            if refreshImmediately { await self?.refresh() }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                await self?.refresh()
            }
        }
    }
    private enum SavedDeviceError: LocalizedError {
        case duplicate
        var errorDescription: String? { "This management address is already saved." }
    }
}
