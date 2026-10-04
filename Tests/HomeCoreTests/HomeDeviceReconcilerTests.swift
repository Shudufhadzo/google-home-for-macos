import XCTest
@testable import HomeCore

final class HomeDeviceReconcilerTests: XCTestCase {
    private var samsung: [HomeDevice] {
        [
            HomeDevice(id: "airplay:1c869a5573c1", name: "Samsung AU7000 50 TV", kind: .television, source: .bonjour, model: "Samsung", host: "192.168.0.5", state: "Discovered", controlNote: "AirPlay", discoveryIDs: ["bonjour:Samsung AU7000 50 TV|_airplay._tcp.|local."], capabilities: [.airPlay], identityKeys: ["airplay:1c869a5573c1"], hostAliases: ["Samsung.local."]),
            HomeDevice(id: "ssdp:uuid:e7fffcc9-e68c-4b66-b10c-54e74ee761fc", name: "Samsung AU7000 50 TV", kind: .television, source: .ssdp, model: "Samsung Electronics · UA50AU7000KXXA", host: "192.168.0.5", state: "Discovered", controlNote: "UPnP"),
            HomeDevice(id: "ssdp:uuid:67492650-112c-4346-861a-bf959c35afb1", name: "Samsung AU7000 50 TV", kind: .other, source: .ssdp, model: "Samsung · UA50AU7000KXXA", host: "192.168.0.5", state: "Discovered", controlNote: "DIAL")
        ]
    }

    func testSamsungAirPlayMediaRendererAndDIALBecomeOneTV() throws {
        let devices = HomeDeviceReconciler.reconcile(samsung)
        XCTAssertEqual(devices.count, 1, "One TV advertises three services, not three physical devices")
        let device = try XCTUnwrap(devices.first)
        XCTAssertEqual(device.kind, .television)
        XCTAssertEqual(device.capabilities, [.airPlay, .upnp])
        XCTAssertEqual(device.sources, [.bonjour, .ssdp])
        XCTAssertEqual(device.discoveryIDs.count, 4)
        XCTAssertTrue(device.model.contains("UA50AU7000KXXA"))
        XCTAssertEqual(device.id, samsung[0].id)
    }

    func testArrivalOrderDoesNotChangeTheMergedIdentityOrDetails() {
        let expected = HomeDeviceReconciler.reconcile(samsung)
        for records in [Array(samsung.reversed()), [samsung[1], samsung[0], samsung[2]], [samsung[2], samsung[0], samsung[1]]] {
            XCTAssertEqual(HomeDeviceReconciler.reconcile(records), expected)
        }
    }

    func testExpiryRemovesOnlyTheExpiredServicesCapabilities() throws {
        let withoutAirPlay = HomeDeviceReconciler.reconcile(Array(samsung.dropFirst()))
        XCTAssertEqual(withoutAirPlay.count, 1)
        XCTAssertFalse(try XCTUnwrap(withoutAirPlay.first).capabilities.contains(.airPlay))
        let airPlayOnly = HomeDeviceReconciler.reconcile([samsung[0]])
        XCTAssertEqual(airPlayOnly.count, 1)
        XCTAssertEqual(airPlayOnly[0].capabilities, [.airPlay])
    }

    func testRouterEmbeddedServicesBecomeOneRouter() {
        let records = ["37", "38", "39"].map {
            HomeDevice(id: "ssdp:uuid:9f0865b3-f5da-4ad5-85b7-7404637fdf\($0)", name: "EX511", kind: .router, source: .ssdp, model: "TP-Link · EX511", host: "192.168.0.1", managementURL: URL(string: "http://192.168.0.1/"), state: "Discovered", controlNote: "Router")
        }
        XCTAssertEqual(HomeDeviceReconciler.reconcile(records).count, 1)
    }

    func testSharedRootUDNReconcilesEmbeddedServiceAliasesDespiteNames() {
        let rootID = "ssdp:uuid:router-root"
        let records = ["root", "wan", "connection"].map {
            HomeDevice(id: rootID, name: $0, kind: .router, source: .ssdp, host: "192.168.0.1", state: "Discovered", controlNote: "", discoveryIDs: ["ssdp:uuid:\($0)"], identityKeys: [rootID])
        }
        let result = HomeDeviceReconciler.reconcile(records)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].discoveryIDs, [rootID, "ssdp:uuid:root", "ssdp:uuid:wan", "ssdp:uuid:connection"])
    }

    func testSameNameOnDifferentHostsIsNotEnoughToMerge() {
        var second = samsung[1]
        second.host = "192.168.0.25"; second.hostAliases = ["192.168.0.25"]
        XCTAssertEqual(HomeDeviceReconciler.reconcile([samsung[0], second]).count, 2)
    }

    func testHostnameAliasesMatchNumericObservation() {
        var second = samsung[1]
        second.host = "samsung.local"; second.hostAliases = ["samsung.local"]
        XCTAssertEqual(HomeDeviceReconciler.reconcile([samsung[0], second]).count, 1)
    }

    func testHAEntitiesManualURLsAndCastGroupsKeepTheirOwnControls() {
        let records = [
            HomeDevice(id: "ha:hub:media_player.tv", name: "TV", kind: .television, source: .homeAssistant, host: "192.168.0.5", state: "on", controlNote: ""),
            HomeDevice(id: "ha:hub:media_player.radio", name: "TV", kind: .television, source: .homeAssistant, host: "192.168.0.5", state: "on", controlNote: ""),
            HomeDevice(id: "manual:one", name: "TV", kind: .television, source: .manual, host: "192.168.0.5", managementURL: URL(string: "http://192.168.0.5/one"), state: "Saved", controlNote: ""),
            HomeDevice(id: "manual:two", name: "TV", kind: .television, source: .manual, host: "192.168.0.5", managementURL: URL(string: "http://192.168.0.5/two"), state: "Saved", controlNote: ""),
            HomeDevice(id: "cast:one", name: "TV", kind: .television, source: .cast, host: "192.168.0.5", state: "Discovered", controlNote: ""),
            HomeDevice(id: "cast:two", name: "TV", kind: .television, source: .cast, host: "192.168.0.5", state: "Discovered", controlNote: "", capabilities: [.castGroup])
        ]
        XCTAssertEqual(HomeDeviceReconciler.reconcile(records).count, records.count)
        XCTAssertEqual(HomeDeviceReconciler.reconcile(records).filter { $0.source == .manual }.compactMap(\.managementURL).count, 2)
    }

    func testNetworkObservationDoesNotJoinDistinctCastReceiversOnOneHost() {
        let casts = ["a", "b"].map {
            HomeDevice(id: "cast:\($0)", name: samsung[0].name, kind: .television, source: .cast, host: "192.168.0.5", state: "Discovered", controlNote: "")
        }
        let result = HomeDeviceReconciler.reconcile(casts + samsung)
        XCTAssertEqual(result.filter { $0.source == .cast }.count, 2)
        XCTAssertTrue(result.contains { $0.id == "cast:a" })
        XCTAssertTrue(result.contains { $0.id == "cast:b" })
    }

    func testDifferentAirPlayIdentitiesCannotBeJoinedThroughUPnP() {
        let second = HomeDevice(id: "airplay:second", name: samsung[0].name, kind: .television, source: .bonjour, host: "192.168.0.5", state: "Discovered", controlNote: "", capabilities: [.airPlay], identityKeys: ["airplay:second"])
        let result = HomeDeviceReconciler.reconcile(samsung + [second])
        XCTAssertEqual(result.filter { $0.capabilities.contains(.airPlay) }.count, 2)
    }

    func testManagementURLSurvivesHTTPMergeButGatewayAddressIsNotAPersistedAlias() throws {
        let http = HomeDevice(id: "bonjour:TV|_http._tcp.|local.", name: "TV admin", kind: .other, source: .bonjour, host: "192.168.0.5", managementURL: URL(string: "http://192.168.0.5/admin"), state: "Discovered", controlNote: "")
        let tv = try XCTUnwrap(HomeDeviceReconciler.reconcile(samsung + [http]).first)
        XCTAssertEqual(tv.managementURL, http.managementURL)
        XCTAssertTrue(tv.capabilities.contains(.airPlay))
        let router = HomeDevice(id: "ssdp:uuid:router", name: "Router", kind: .router, source: .ssdp, host: "192.168.0.1", state: "Discovered", controlNote: "")
        let route = HomeDevice(id: "gateway:192.168.0.1", name: "Gateway", kind: .router, source: .gateway, host: "192.168.0.1", managementURL: URL(string: "http://192.168.0.1/"), state: "Current route", controlNote: "")
        let result = HomeDeviceReconciler.reconcile([route, router])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, router.id)
        XCTAssertFalse(result[0].discoveryIDs.contains(route.id))
        XCTAssertEqual(result[0].managementURL, route.managementURL)
    }
}
