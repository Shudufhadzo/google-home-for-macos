import Foundation

/// Categories describe what a device advertises, never the controls its brand might support.
public enum HomeDeviceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case speaker, television, light, outlet, fan, climate, cover, vacuum, sensor, camera, lock
    case router, extender, bridge, accessory, other

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .speaker: return "Speaker"
        case .television: return "TV / media"
        case .light: return "Light"
        case .outlet: return "Switch / outlet"
        case .fan: return "Fan"
        case .climate: return "Climate"
        case .cover: return "Blind / cover"
        case .vacuum: return "Vacuum"
        case .sensor: return "Sensor"
        case .camera: return "Camera"
        case .lock: return "Lock"
        case .router: return "Router"
        case .extender: return "Extender / access point"
        case .bridge: return "Home hub"
        case .accessory: return "Smart accessory"
        case .other: return "Device"
        }
    }
    public var symbol: String {
        switch self {
        case .speaker: return "hifispeaker.fill"
        case .television: return "tv"
        case .light: return "lightbulb.fill"
        case .outlet: return "powerplug.fill"
        case .fan: return "fan.fill"
        case .climate: return "thermometer.medium"
        case .cover: return "blinds.horizontal.closed"
        case .vacuum: return "robotic.vacuum"
        case .sensor: return "sensor.fill"
        case .camera: return "video.fill"
        case .lock: return "lock.fill"
        case .router: return "wifi.router.fill"
        case .extender: return "wifi"
        case .bridge: return "house.fill"
        case .accessory: return "switch.2"
        case .other: return "square.grid.2x2"
        }
    }
    public var isNetworkEquipment: Bool { self == .router || self == .extender }
}

public enum HomeDeviceSource: String, Codable, Hashable, Sendable {
    case cast, homeAssistant, bonjour, ssdp, gateway, manual
    public var title: String {
        switch self {
        case .cast: return "Google Cast"
        case .homeAssistant: return "Home Assistant"
        case .bonjour: return "Bonjour"
        case .ssdp: return "UPnP"
        case .gateway: return "Mac network route"
        case .manual: return "Saved device"
        }
    }
}

public enum HomeDeviceCapability: String, Hashable, Sendable {
    case airPlay, googleCast, castGroup, upnp, webManagement
    public var title: String {
        switch self {
        case .airPlay: return "AirPlay"
        case .googleCast: return "Google Cast"
        case .castGroup: return "Google Home group"
        case .upnp: return "UPnP"
        case .webManagement: return "Web management"
        }
    }
}

public struct HomeDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var kind: HomeDeviceKind
    public var source: HomeDeviceSource
    public var model: String
    public var host: String?
    public var managementURL: URL?
    public var state: String
    public var controlNote: String
    /// Every observed service remains an alias for room/favourite assignments.
    public var discoveryIDs: Set<String>
    public var sources: Set<HomeDeviceSource>
    public var capabilities: Set<HomeDeviceCapability>
    /// Protocol identities, such as a root UPnP UDN or AirPlay device ID. Never an IP address.
    public var identityKeys: Set<String>
    /// Addresses observed together during this scan; used only for current reconciliation.
    public var hostAliases: Set<String>

    public var connectionSummary: String {
        let titles = [HomeDeviceCapability.googleCast, .castGroup, .airPlay, .upnp, .webManagement]
            .filter { capabilities.contains($0) }.map(\.title)
        return titles.isEmpty ? source.title : titles.joined(separator: " · ")
    }

    public init(id: String, name: String, kind: HomeDeviceKind, source: HomeDeviceSource,
                model: String = "", host: String? = nil, managementURL: URL? = nil,
                state: String, controlNote: String, discoveryIDs: Set<String> = [],
                sources: Set<HomeDeviceSource> = [], capabilities: Set<HomeDeviceCapability> = [],
                identityKeys: Set<String> = [], hostAliases: Set<String> = []) {
        self.id = id; self.name = name; self.kind = kind; self.source = source
        self.model = model; self.host = host; self.managementURL = managementURL
        self.state = state; self.controlNote = controlNote
        self.discoveryIDs = discoveryIDs.union([id]); self.sources = sources.union([source])
        self.capabilities = capabilities
        if source == .cast { self.capabilities.insert(.googleCast) }
        if source == .ssdp { self.capabilities.insert(.upnp) }
        if managementURL != nil { self.capabilities.insert(.webManagement) }
        self.identityKeys = identityKeys
        self.hostAliases = hostAliases.union(host.map { [$0] } ?? [])
    }
}

public struct DeviceAnnotation: Codable, Equatable, Sendable {
    public var room: String
    public var isFavorite: Bool
    public init(room: String = "", isFavorite: Bool = false) {
        self.room = room; self.isFavorite = isFavorite
    }
}

public struct SavedHomeDevice: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: HomeDeviceKind
    public var url: URL
    public init(id: UUID = UUID(), name: String, kind: HomeDeviceKind, url: URL) {
        self.id = id; self.name = name; self.kind = kind; self.url = url
    }
    public var device: HomeDevice {
        HomeDevice(id: "manual:\(id.uuidString)", name: name, kind: kind, source: .manual,
                   host: url.host, managementURL: url, state: "Saved address",
                   controlNote: "Open the device's own management page to configure it.")
    }
}

public enum HomeConnectionError: LocalizedError, Equatable {
    case invalidAddress, insecureAddress, invalidResponse, unauthorized, http(Int)
    case unsupportedControl, invalidValue, missingCredential
    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter an HTTP or HTTPS address without a password, query, or fragment."
        case .insecureAddress: return "Use HTTPS, or HTTP with a private LAN IP address or a .local hostname."
        case .invalidResponse: return "The server returned an unexpected response. Check the address and API access."
        case .unauthorized: return "Home Assistant refused access. Check the long-lived access token and account permissions."
        case .http(let code): return "The server returned HTTP \(code)."
        case .unsupportedControl: return "This device does not currently advertise that control."
        case .invalidValue: return "That setting is outside the device's supported range."
        case .missingCredential: return "Reconnect Home Assistant with a long-lived access token."
        }
    }
}

/// Shared by manual configuration, authenticated APIs, and untrusted LAN advertisements.
public enum HomeEndpointPolicy {
    public static func address(_ input: String, localOnly: Bool = false) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }),
              var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw HomeConnectionError.invalidAddress
        }
        if (localOnly || scheme == "http") && !isLocalHost(host) {
            throw HomeConnectionError.insecureAddress
        }
        components.scheme = scheme
        components.host = host.lowercased()
        guard let url = components.url else { throw HomeConnectionError.invalidAddress }
        return url
    }

    public static func isLocalHost(_ input: String) -> Bool {
        let host = input.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            return (bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
        }
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return false }
        let numbers = pieces.compactMap { part -> UInt8? in
            // Reject octal-looking forms and noncanonical URL host encodings.
            guard part.allSatisfy(\.isNumber), part.count == 1 || !part.hasPrefix("0") else { return nil }
            return UInt8(part)
        }
        guard numbers.count == 4 else { return false }
        return numbers[0] == 10 || numbers[0] == 127 ||
            (numbers[0] == 192 && numbers[1] == 168) ||
            (numbers[0] == 172 && (16...31).contains(numbers[1])) ||
            (numbers[0] == 169 && numbers[1] == 254)
    }

    public static func localURL(host: String, port: Int = 80, secure: Bool = false) -> URL? {
        var components = URLComponents()
        components.scheme = secure ? "https" : "http"
        components.host = host
        components.port = port
        guard let url = components.url else { return nil }
        return try? address(url.absoluteString, localOnly: true)
    }
}
