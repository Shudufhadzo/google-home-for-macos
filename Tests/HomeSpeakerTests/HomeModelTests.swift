import HomeCore
import XCTest
@testable import HomeSpeaker

private final class MemoryHomeSettings: HomeSettingsPersisting {
    var settings = HomeSettings()
    func load() throws -> HomeSettings { settings }
    func save(_ settings: HomeSettings) throws { self.settings = settings }
}

private final class MemoryHomeCredentials: HomeCredentialStoring, @unchecked Sendable {
    var tokens: [String: String] = [:]
    func read(account: String) throws -> String? { tokens[account] }
    func save(_ token: String, account: String) throws { tokens[account] = token }
    func remove(account: String) throws { tokens.removeValue(forKey: account) }
}

private final class StartupCheckingCredentials: HomeCredentialStoring, @unchecked Sendable {
    let readExpectation: XCTestExpectation
    var readOnMainThread = false
    init(_ expectation: XCTestExpectation) { readExpectation = expectation }
    func read(account: String) throws -> String? {
        readOnMainThread = Thread.isMainThread
        readExpectation.fulfill()
        return nil
    }
    func save(_ token: String, account: String) throws {}
    func remove(account: String) throws {}
}

private actor ModelFixtureHub: HomeAssistantConnecting {
    let data: HomeSnapshot
    var snapshotError: HomeConnectionError?
    var calls = 0
    var shouldWait = false
    var pending: CheckedContinuation<HomeSnapshot, Error>?
    var pendingObserver: CheckedContinuation<Void, Never>?
    init() throws {
        let entity = try JSONDecoder().decode(HomeEntity.self, from: Data("{\"entity_id\":\"switch.demo\",\"state\":\"off\",\"attributes\":{\"friendly_name\":\"Fixture switch\"}}".utf8))
        data = HomeSnapshot(entities: [entity], services: .init(domains: ["switch": ["turn_on", "turn_off"]]))
    }
    func snapshot() async throws -> HomeSnapshot {
        if let snapshotError { throw snapshotError }
        if shouldWait {
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation; pendingObserver?.resume(); pendingObserver = nil
            }
        }
        return data
    }
    func perform(_ command: HomeCommand, entity: HomeEntity, services: HomeServiceCatalog) async throws { calls += 1 }
    func failNext() { snapshotError = .http(503) }
    func delayNext() { shouldWait = true }
    func waitUntilPending() async {
        if pending != nil { return }
        await withCheckedContinuation { pendingObserver = $0 }
    }
    func resume() { pending?.resume(returning: data); pending = nil }
}

final class HomeModelTests: XCTestCase {
    @MainActor
    func testRoomAndFavoriteOnOldTVServiceSurviveReconciliationExpiryAndReload() throws {
        let store = MemoryHomeSettings(), vault = MemoryHomeCredentials()
        let oldID = "bonjour:Samsung TV|_airplay._tcp.|local."
        store.settings.annotations[oldID] = DeviceAnnotation(room: "Lounge", isFavorite: true)
        let airPlay = HomeDevice(id: "airplay:tv", name: "Samsung TV", kind: .television, source: .bonjour, host: "192.168.0.5", state: "Discovered", controlNote: "", discoveryIDs: [oldID], capabilities: [.airPlay])
        let upnp = HomeDevice(id: "ssdp:uuid:tv", name: "Samsung TV", kind: .television, source: .ssdp, host: "192.168.0.5", state: "Discovered", controlNote: "")
        let home = HomeModel(persistence: store, credentials: vault)
        home.acceptNetworkDevices([upnp, airPlay])
        let tv = try XCTUnwrap(home.devices(cast: []).first)
        XCTAssertEqual(home.devices(cast: []).count, 1)
        XCTAssertEqual(home.annotation(tv.id), .init(room: "Lounge", isFavorite: true))
        home.acceptNetworkDevices([upnp])
        XCTAssertEqual(home.annotation(upnp.id), .init(room: "Lounge", isFavorite: true))
        home.saveAnnotation(upnp.id, room: "Living room", favorite: false)
        let reloaded = HomeModel(persistence: store, credentials: vault)
        reloaded.acceptNetworkDevices([airPlay])
        XCTAssertEqual(reloaded.annotation(airPlay.id), .init(room: "Living room", isFavorite: false))
        XCTAssertEqual(reloaded.annotation(oldID), .init(room: "Living room", isFavorite: false))
    }

    @MainActor
    func testCastGroupOnSameHostRemainsSelectableAlongsidePhysicalDevice() {
        let home = HomeModel(persistence: MemoryHomeSettings(), credentials: MemoryHomeCredentials())
        let airPlay = HomeDevice(id: "airplay:tv", name: "TV", kind: .television, source: .bonjour, host: "192.168.0.5", state: "Discovered", controlNote: "", capabilities: [.airPlay])
        home.acceptNetworkDevices([airPlay])
        let cast = CastDevice(id: "tv", name: "TV", model: "Chromecast", host: "192.168.0.5", port: 8009)
        let group = CastDevice(id: "Google-Cast-Group-house", name: "TV", model: "Google Cast Group", host: "192.168.0.5", port: 32100)
        let result = home.devices(cast: [cast, group])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains { $0.id == "cast:tv" && $0.capabilities.contains(.airPlay) })
        XCTAssertTrue(result.contains { $0.id == "cast:Google-Cast-Group-house" && $0.capabilities.contains(.castGroup) })
    }

    @MainActor
    func testStartupKeychainLookupDoesNotBlockTheUIThread() async throws {
        let store = MemoryHomeSettings()
        store.settings.bridge = HomeBridgeConfiguration(id: UUID(), url: URL(string: "http://127.0.0.1:8123")!)
        let read = expectation(description: "Startup credential lookup")
        let vault = StartupCheckingCredentials(read)
        let home = HomeModel(persistence: store, credentials: vault)
        home.start(); defer { home.stop() }
        await fulfillment(of: [read], timeout: 2)
        XCTAssertFalse(vault.readOnMainThread, "Keychain operations can wait for OS approval and must not block window rendering")
    }
    @MainActor
    func testSavedDeviceRoomAndFavoriteSurviveReloadWithoutSecretsInPreferences() throws {
        let store = MemoryHomeSettings(), vault = MemoryHomeCredentials()
        let home = HomeModel(persistence: store, credentials: vault)
        try home.addDevice(name: "Office extender", kind: .extender, address: "http://192.168.1.20", room: "Office")
        let device = try XCTUnwrap(home.devices(cast: []).first)
        XCTAssertEqual(device.state, "Saved address")
        home.toggleFavorite(device.id)
        let reloaded = HomeModel(persistence: store, credentials: vault)
        XCTAssertEqual(reloaded.annotation(device.id), .init(room: "Office", isFavorite: true))
        XCTAssertThrowsError(try home.addDevice(name: "Duplicate", kind: .router, address: "http://192.168.1.20", room: ""))
        XCTAssertThrowsError(try home.addDevice(name: "External", kind: .router, address: "https://example.com", room: ""))
        home.removeSavedDevice(device.id)
        XCTAssertTrue(store.settings.devices.isEmpty)
    }

    @MainActor
    func testFailedReconnectPreservesWorkingBridgeAndKeychainItem() async throws {
        let hub = try ModelFixtureHub(), store = MemoryHomeSettings(), vault = MemoryHomeCredentials()
        let home = HomeModel(persistence: store, credentials: vault, clientFactory: { _, token in
            if token == "refused" { throw HomeConnectionError.unauthorized }; return hub
        })
        defer { home.stop() }
        let connected = await home.connect(address: "http://127.0.0.1:8123", token: "fixture-only-token")
        XCTAssertTrue(connected)
        let original = try XCTUnwrap(home.settings.bridge)
        let failed = await home.connect(address: "http://127.0.0.1:8124", token: "refused")
        XCTAssertFalse(failed)
        XCTAssertEqual(home.settings.bridge, original)
        XCTAssertTrue(home.bridgeConnected)
        XCTAssertEqual(vault.tokens.count, 1)
        let saved = String(data: try JSONEncoder().encode(store.settings), encoding: .utf8)!
        XCTAssertFalse(saved.contains("fixture-only-token"))
    }

    @MainActor
    func testOfflineHubKeepsLastStateAndDisablesCommands() async throws {
        let hub = try ModelFixtureHub(), store = MemoryHomeSettings(), vault = MemoryHomeCredentials()
        let home = HomeModel(persistence: store, credentials: vault, clientFactory: { _, _ in hub })
        defer { home.stop() }
        _ = await home.connect(address: "http://127.0.0.1:8123", token: "fixture")
        await hub.failNext(); await home.refresh()
        XCTAssertFalse(home.bridgeConnected)
        XCTAssertEqual(home.entities.count, 1)
        XCTAssertTrue(try XCTUnwrap(home.devices(cast: []).first?.state).hasPrefix("Last known:"))
        await home.perform(.action(.turnOn), entityID: "switch.demo")
        let count = await hub.calls
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testLateRefreshCannotRestoreDisconnectedDevices() async throws {
        let hub = try ModelFixtureHub(), store = MemoryHomeSettings(), vault = MemoryHomeCredentials()
        let home = HomeModel(persistence: store, credentials: vault, clientFactory: { _, _ in hub })
        defer { home.stop() }
        _ = await home.connect(address: "http://127.0.0.1:8123", token: "fixture")
        await hub.delayNext()
        let refreshing = Task { await home.refresh() }
        await hub.waitUntilPending()
        await home.disconnectBridge()
        await hub.resume(); await refreshing.value
        XCTAssertNil(home.settings.bridge)
        XCTAssertTrue(home.entities.isEmpty)
        XCTAssertTrue(vault.tokens.isEmpty)
        XCTAssertFalse(home.bridgeConnected)
    }

    @MainActor
    func testReconnectToSameServerKeepsRoomAssignments() async throws {
        let hub = try ModelFixtureHub(), store = MemoryHomeSettings(), vault = MemoryHomeCredentials()
        let home = HomeModel(persistence: store, credentials: vault, clientFactory: { _, _ in hub })
        defer { home.stop() }
        _ = await home.connect(address: "http://127.0.0.1:8123", token: "fixture-one")
        let original = try XCTUnwrap(home.devices(cast: []).first)
        home.saveAnnotation(original.id, room: "Study", favorite: true)
        _ = await home.connect(address: "http://127.0.0.1:8123", token: "fixture-two")
        let new = try XCTUnwrap(home.devices(cast: []).first)
        XCTAssertEqual(home.annotation(new.id), .init(room: "Study", isFavorite: true))
        XCTAssertEqual(vault.tokens.count, 1)
    }
}
