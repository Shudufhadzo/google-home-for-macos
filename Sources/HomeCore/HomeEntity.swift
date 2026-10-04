import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var number: Double? { if case .number(let value) = self { return value }; return nil }
    public var strings: [String] { if case .array(let values) = self { return values.compactMap(\.string) }; return [] }
}

public struct HomeEntity: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let state: String
    public let attributes: [String: JSONValue]
    enum CodingKeys: String, CodingKey { case id = "entity_id", state, attributes }
    public var domain: String { id.components(separatedBy: ".").first ?? "" }
    public var name: String { attributes["friendly_name"]?.string ?? id }
    public var available: Bool {
        // A scene has no state until its first activation; Home Assistant serializes
        // that missing timestamp as "unknown". It can still be activated.
        state != "unavailable" && (state != "unknown" || domain == "scene")
    }
    public var features: UInt64 {
        guard let number = attributes["supported_features"]?.number, number.isFinite,
              number >= 0, number < Double(UInt64.max) else { return 0 }
        return UInt64(number)
    }
    public func supports(_ mask: UInt64) -> Bool { features & mask == mask }
    public var kind: HomeDeviceKind {
        switch domain {
        case "light": return .light
        case "switch", "input_boolean": return .outlet
        case "fan": return .fan
        case "climate", "humidifier", "water_heater": return .climate
        case "cover": return .cover
        case "vacuum": return .vacuum
        case "sensor", "binary_sensor", "device_tracker", "weather": return .sensor
        case "camera": return .camera
        case "lock", "alarm_control_panel": return .lock
        case "media_player": return attributes["device_class"]?.string == "speaker" ? .speaker : .television
        default: return .accessory
        }
    }
    public var displayState: String {
        let unit = attributes["unit_of_measurement"]?.string ?? ""
        return unit.isEmpty ? state.replacingOccurrences(of: "_", with: " ").capitalized : "\(state) \(unit)"
    }
    public func device(bridgeID: UUID, baseURL: URL) -> HomeDevice {
        HomeDevice(id: "ha:\(bridgeID.uuidString):\(id)", name: name, kind: kind, source: .homeAssistant,
                   model: id, host: baseURL.host, managementURL: baseURL,
                   state: displayState, controlNote: "Managed through your Home Assistant integrations.")
    }
}

public struct HomeServiceCatalog: Equatable, Sendable {
    private var domains: [String: Set<String>]
    public init(domains: [String: Set<String>]) { self.domains = domains }
    public func contains(_ domain: String, _ service: String) -> Bool { domains[domain]?.contains(service) == true }
    public static func decode(_ data: Data) throws -> HomeServiceCatalog {
        struct Domain: Decodable { let domain: String; let services: [String: JSONValue] }
        let records = try JSONDecoder().decode([Domain].self, from: data)
        return HomeServiceCatalog(domains: records.reduce(into: [:]) { $0[$1.domain] = Set($1.services.keys) })
    }
}

public enum HomeAction: String, CaseIterable, Identifiable, Sendable {
    case turnOn, turnOff, open, close, stop, play, pause, startCleaning, returnToBase, activate
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .turnOn: return "Turn on"
        case .turnOff: return "Turn off"
        case .open: return "Open"
        case .close: return "Close"
        case .stop: return "Stop"
        case .play: return "Play"
        case .pause: return "Pause"
        case .startCleaning: return "Start cleaning"
        case .returnToBase: return "Return to dock"
        case .activate: return "Run"
        }
    }
}

public struct HomeAdjustment: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case brightness, temperature, fanSpeed, volume }
    public let kind: Kind
    public let value: Double
    public let range: ClosedRange<Double>
    public let step: Double
    public let unit: String
    public var id: String { kind.rawValue }
    public var title: String {
        switch kind {
        case .brightness: return "Brightness"
        case .temperature: return "Target temperature"
        case .fanSpeed: return "Fan speed"
        case .volume: return "Volume"
        }
    }
}

public enum HomeCommand: Sendable { case action(HomeAction), adjust(HomeAdjustment.Kind, Double) }
public struct HomeServiceCall: Equatable, Sendable {
    public let domain: String
    public let service: String
    public let data: [String: JSONValue]
}

/// Every button requires both the entity's capabilities and a service present on this server.
/// Feature masks follow Home Assistant Core's entity enums (linked in docs/DEVICE-SUPPORT.md).
public enum HomeControls {
    public static func actions(for entity: HomeEntity, services: HomeServiceCatalog) -> [HomeAction] {
        guard entity.available else { return [] }
        return HomeAction.allCases.filter { actionService($0, entity: entity, services: services) != nil }
    }

    private static func actionService(_ action: HomeAction, entity: HomeEntity, services: HomeServiceCatalog) -> String? {
        let domain = entity.domain
        let service: String?
        switch (domain, action) {
        case ("light", .turnOn), ("switch", .turnOn), ("input_boolean", .turnOn), ("automation", .turnOn): service = "turn_on"
        case ("light", .turnOff), ("switch", .turnOff), ("input_boolean", .turnOff), ("automation", .turnOff): service = "turn_off"
        case ("fan", .turnOn): service = entity.supports(32) ? "turn_on" : nil
        case ("fan", .turnOff): service = entity.supports(16) ? "turn_off" : nil
        case ("cover", .open): service = entity.supports(1) ? "open_cover" : nil
        case ("cover", .close): service = entity.supports(2) ? "close_cover" : nil
        case ("cover", .stop): service = entity.supports(8) ? "stop_cover" : nil
        case ("media_player", .play): service = entity.supports(16384) ? "media_play" : nil
        case ("media_player", .pause): service = entity.supports(1) ? "media_pause" : nil
        case ("media_player", .stop): service = entity.supports(4096) ? "media_stop" : nil
        case ("vacuum", .startCleaning): service = entity.supports(8192) ? "start" : nil
        case ("vacuum", .pause): service = entity.supports(4) ? "pause" : nil
        case ("vacuum", .stop): service = entity.supports(8) ? "stop" : nil
        case ("vacuum", .returnToBase): service = entity.supports(16) ? "return_to_base" : nil
        case ("scene", .activate), ("script", .activate): service = "turn_on"
        default: service = nil
        }
        guard let service, services.contains(domain, service) else { return nil }
        return service
    }

    public static func adjustments(for entity: HomeEntity, services: HomeServiceCatalog) -> [HomeAdjustment] {
        guard entity.available else { return [] }
        switch entity.domain {
        case "light" where services.contains("light", "turn_on"):
            let modes = entity.attributes["supported_color_modes"]?.strings ?? []
            guard modes.contains(where: { !["onoff", "unknown"].contains($0) }) else { return [] }
            return [.init(kind: .brightness, value: (entity.attributes["brightness"]?.number ?? 0) / 255 * 100,
                          range: 1...100, step: 1, unit: "%")]
        case "fan" where entity.supports(1) && services.contains("fan", "set_percentage"):
            return [.init(kind: .fanSpeed, value: entity.attributes["percentage"]?.number ?? 0, range: 0...100, step: 1, unit: "%")]
        case "media_player" where entity.supports(4) && services.contains("media_player", "volume_set"):
            return [.init(kind: .volume, value: (entity.attributes["volume_level"]?.number ?? 0) * 100, range: 0...100, step: 1, unit: "%")]
        case "climate" where entity.supports(1) && services.contains("climate", "set_temperature"):
            guard let low = entity.attributes["min_temp"]?.number, let high = entity.attributes["max_temp"]?.number,
                  let value = entity.attributes["temperature"]?.number,
                  low.isFinite, high.isFinite, value.isFinite, low < high else { return [] }
            let step = entity.attributes["target_temp_step"]?.number ?? 0.5
            return [.init(kind: .temperature, value: value, range: low...high,
                          step: step.isFinite && step > 0 ? step : 0.5,
                          unit: entity.attributes["temperature_unit"]?.string ?? "")]
        default: return []
        }
    }

    public static func call(_ command: HomeCommand, entity: HomeEntity, services: HomeServiceCatalog) throws -> HomeServiceCall {
        guard entity.available, entity.id.range(of: "^[a-z_]+\\.[a-z0-9_]+$", options: .regularExpression) != nil else {
            throw HomeConnectionError.unsupportedControl
        }
        var payload: [String: JSONValue] = ["entity_id": .string(entity.id)]
        let service: String
        switch command {
        case .action(let action):
            guard let resolved = actionService(action, entity: entity, services: services) else { throw HomeConnectionError.unsupportedControl }
            service = resolved
        case .adjust(let kind, let value):
            guard let adjustment = adjustments(for: entity, services: services).first(where: { $0.kind == kind }) else {
                throw HomeConnectionError.unsupportedControl
            }
            guard value.isFinite, adjustment.range.contains(value) else { throw HomeConnectionError.invalidValue }
            switch kind {
            case .brightness: service = "turn_on"; payload["brightness_pct"] = .number(value.rounded())
            case .temperature: service = "set_temperature"; payload["temperature"] = .number(value)
            case .fanSpeed: service = "set_percentage"; payload["percentage"] = .number(value.rounded())
            case .volume: service = "volume_set"; payload["volume_level"] = .number(value / 100)
            }
        }
        return HomeServiceCall(domain: entity.domain, service: service, data: payload)
    }
}
