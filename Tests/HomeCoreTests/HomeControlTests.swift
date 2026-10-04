import XCTest
@testable import HomeCore

final class HomeControlTests: XCTestCase {
    private func entity(_ id: String, state: String = "on", attributes: String = "{}") throws -> HomeEntity {
        try JSONDecoder().decode(HomeEntity.self, from: Data("{\"entity_id\":\"\(id)\",\"state\":\"\(state)\",\"attributes\":\(attributes)}".utf8))
    }

    func testCapabilitiesRequireEntityFeaturesAndAvailableServices() throws {
        let cover = try entity("cover.study", attributes: "{\"supported_features\":9}")
        let services = HomeServiceCatalog(domains: ["cover": ["open_cover", "close_cover", "stop_cover"]])
        XCTAssertEqual(HomeControls.actions(for: cover, services: services), [.open, .stop])
        XCTAssertThrowsError(try HomeControls.call(.action(.close), entity: cover, services: services))
        XCTAssertTrue(HomeControls.actions(for: cover, services: .init(domains: [:])).isEmpty)
        let offline = try entity("cover.study", state: "unavailable", attributes: "{\"supported_features\":15}")
        XCTAssertTrue(HomeControls.actions(for: offline, services: services).isEmpty)
        XCTAssertThrowsError(try HomeControls.call(.action(.open), entity: offline, services: services))
    }

    func testOnOffBulbsDoNotAdvertiseBrightness() throws {
        let services = HomeServiceCatalog(domains: ["light": ["turn_on", "turn_off"]])
        let binary = try entity("light.porch", attributes: "{\"supported_color_modes\":[\"onoff\"]}")
        XCTAssertEqual(HomeControls.actions(for: binary, services: services), [.turnOn, .turnOff])
        XCTAssertTrue(HomeControls.adjustments(for: binary, services: services).isEmpty)
        let dimmable = try entity("light.study", attributes: "{\"supported_color_modes\":[\"brightness\"],\"brightness\":128}")
        let call = try HomeControls.call(.adjust(.brightness, 50), entity: dimmable, services: services)
        XCTAssertEqual(call.service, "turn_on")
        XCTAssertEqual(call.data["brightness_pct"], .number(50))
        XCTAssertThrowsError(try HomeControls.call(.adjust(.brightness, .nan), entity: dimmable, services: services))
        XCTAssertThrowsError(try HomeControls.call(.adjust(.brightness, 101), entity: dimmable, services: services))
    }

    func testClimateRangesAndReadOnlyEntities() throws {
        let thermostat = try entity("climate.bedroom", state: "heat", attributes: "{\"supported_features\":1,\"min_temp\":16,\"max_temp\":30,\"temperature\":21,\"target_temp_step\":0.5}")
        let services = HomeServiceCatalog(domains: ["climate": ["set_temperature"], "lock": ["unlock"], "sensor": ["turn_on"]])
        let call = try HomeControls.call(.adjust(.temperature, 22.5), entity: thermostat, services: services)
        XCTAssertEqual(call.data["temperature"], .number(22.5))
        XCTAssertThrowsError(try HomeControls.call(.adjust(.temperature, 35), entity: thermostat, services: services))
        for id in ["lock.front_door", "sensor.temperature", "camera.porch"] {
            XCTAssertTrue(HomeControls.actions(for: try entity(id), services: services).isEmpty)
        }
    }

    func testServiceCatalogDecodesActualRESTDictionaryShape() throws {
        let data = Data("[{\"domain\":\"light\",\"services\":{\"turn_on\":{\"fields\":{},\"target\":{}},\"turn_off\":{}}}]".utf8)
        let services = try HomeServiceCatalog.decode(data)
        XCTAssertTrue(services.contains("light", "turn_on"))
        XCTAssertFalse(services.contains("switch", "turn_on"))
    }

    func testSceneWithoutAnActivationTimestampCanStillRun() throws {
        // Home Assistant scenes return an unknown state before their first activation.
        let services = HomeServiceCatalog(domains: ["scene": ["turn_on"]])
        let scene = try entity("scene.evening", state: "unknown")
        XCTAssertEqual(HomeControls.actions(for: scene, services: services), [.activate])
        XCTAssertEqual(try HomeControls.call(.action(.activate), entity: scene, services: services).service, "turn_on")
        let offline = try entity("scene.evening", state: "unavailable")
        XCTAssertTrue(HomeControls.actions(for: offline, services: services).isEmpty)
        XCTAssertThrowsError(try HomeControls.call(.action(.activate), entity: offline, services: services))
        XCTAssertFalse(try entity("light.unknown", state: "unknown").available)
    }

    func testFanVacuumAndMediaControlsUseSupportedFeatureMasks() throws {
        let fan = try entity("fan.lounge", attributes: "{\"supported_features\":49,\"percentage\":50}")
        let vacuum = try entity("vacuum.xiaomi", state: "docked", attributes: "{\"supported_features\":8220}")
        let media = try entity("media_player.tv", state: "playing", attributes: "{\"supported_features\":16389,\"volume_level\":0.25}")
        let services = HomeServiceCatalog(domains: ["fan": ["turn_on", "turn_off", "set_percentage"],
                                                  "vacuum": ["start", "pause", "stop", "return_to_base"],
                                                  "media_player": ["media_play", "media_pause", "media_stop", "volume_set"]])
        XCTAssertEqual(HomeControls.actions(for: fan, services: services), [.turnOn, .turnOff])
        XCTAssertEqual(HomeControls.actions(for: vacuum, services: services), [.stop, .pause, .startCleaning, .returnToBase])
        XCTAssertEqual(HomeControls.actions(for: media, services: services), [.play, .pause])
        XCTAssertEqual(try HomeControls.call(.adjust(.volume, 40), entity: media, services: services).data["volume_level"], .number(0.4))
    }
}
