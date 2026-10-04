import Foundation

/// Reconciles live service observations without treating an address or friendly name as a durable ID.
public enum HomeDeviceReconciler {
    public static func reconcile(_ records: [HomeDevice]) -> [HomeDevice] {
        // Always choose the same representative regardless of network reply order.
        var groups: [[HomeDevice]] = []
        for record in records.sorted(by: preferred) {
            let matches = groups.indices.filter { index in
                groups[index].contains { matchesIdentity(record, $0) }
            }
            if matches.isEmpty { groups.append([record]); continue }
            // One observation must never join two distinct Cast receivers sharing a host.
            let castIDs = Set((matches.flatMap { groups[$0] } + [record])
                .filter { $0.source == .cast }.map(\.id))
            let airPlayIDs = Set((matches.flatMap { groups[$0] } + [record])
                .flatMap(\.identityKeys).filter { $0.hasPrefix("airplay:") })
            if castIDs.count > 1 || airPlayIDs.count > 1 { groups.append([record]); continue }
            let combined = [record] + matches.flatMap { groups[$0] }
            for index in matches.reversed() { groups.remove(at: index) }
            groups.append(combined)
        }
        // Generic HTTP services and the route entry contribute only when the host has one
        // unambiguous physical device. HomeKit/Matter accessories and hub entities stay separate.
        var deferred: [HomeDevice] = []
        var devices = groups.map(merge).filter {
            if isGenericService($0) || $0.source == .gateway { deferred.append($0); return false }
            return true
        }
        for record in deferred {
            let matches = devices.indices.filter { index in
                let other = devices[index]
                guard !isProtected(other), sharesHost(record, other) else { return false }
                if record.source == .gateway { return other.kind == .router }
                return other.source == .ssdp || other.kind == .bridge || isMedia(other)
            }
            if matches.count == 1, let index = matches.first { devices[index] = merge([devices[index], record]) }
            else { devices.append(record) }
        }
        return devices.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private static func isProtected(_ device: HomeDevice) -> Bool {
        device.source == .homeAssistant || device.source == .manual || device.capabilities.contains(.castGroup)
    }
    private static func isMedia(_ device: HomeDevice) -> Bool { device.kind == .television || device.kind == .speaker }
    private static func isGenericService(_ device: HomeDevice) -> Bool {
        device.source == .bonjour && device.kind == .other &&
            (device.id.contains("|_http._tcp.") || device.id.contains("|_https._tcp."))
    }
    private static func normalizedHost(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
    }
    private static func sharesHost(_ lhs: HomeDevice, _ rhs: HomeDevice) -> Bool {
        let left = Set(lhs.hostAliases.map(normalizedHost).filter { !$0.isEmpty })
        return !left.isDisjoint(with: rhs.hostAliases.map(normalizedHost))
    }
    private static func normalizedName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    private static func matchesIdentity(_ lhs: HomeDevice, _ rhs: HomeDevice) -> Bool {
        if lhs.id == rhs.id { return true }
        guard !isProtected(lhs), !isProtected(rhs) else { return false }
        // Distinct Cast receivers and distinct AirPlay IDs can represent virtual endpoints
        // on the same machine; do not collapse them through a third service observation.
        if lhs.source == .cast && rhs.source == .cast { return false }
        if !lhs.identityKeys.isDisjoint(with: rhs.identityKeys) { return true }
        if !lhs.discoveryIDs.isDisjoint(with: rhs.discoveryIDs) { return true }
        let leftAirPlay = lhs.identityKeys.filter { $0.hasPrefix("airplay:") }
        let rightAirPlay = rhs.identityKeys.filter { $0.hasPrefix("airplay:") }
        if !leftAirPlay.isEmpty && !rightAirPlay.isEmpty && leftAirPlay.isDisjoint(with: rightAirPlay) { return false }
        guard sharesHost(lhs, rhs), !lhs.name.isEmpty, normalizedName(lhs.name) == normalizedName(rhs.name) else { return false }
        if isMedia(lhs) && isMedia(rhs) { return true }
        if lhs.kind.isNetworkEquipment && rhs.kind == lhs.kind { return true }
        // Some UPnP TV services (notably DIAL) are less specific than their AirPlay/renderer record.
        return (isMedia(lhs) && rhs.source == .ssdp && rhs.kind == .other) ||
            (isMedia(rhs) && lhs.source == .ssdp && lhs.kind == .other)
    }

    private static func preferred(_ lhs: HomeDevice, _ rhs: HomeDevice) -> Bool {
        func rank(_ device: HomeDevice) -> Int {
            if device.source == .cast { return 0 }
            if device.capabilities.contains(.airPlay) { return 1 }
            if device.source == .ssdp { return device.kind == .other ? 4 : 2 }
            if device.source == .bonjour { return device.kind == .other ? 5 : 3 }
            return 6
        }
        let left = rank(lhs), right = rank(rhs)
        return left == right ? lhs.id < rhs.id : left < right
    }

    private static func merge(_ records: [HomeDevice]) -> HomeDevice {
        let ordered = records.sorted(by: preferred)
        var device = ordered[0]
        for other in ordered.dropFirst() {
            // A route address may be reused by a different router; never persist it as
            // a physical-device identity alias once a real router identity is available.
            if other.source != .gateway { device.discoveryIDs.formUnion(other.discoveryIDs) }
            device.identityKeys.formUnion(other.identityKeys)
            device.hostAliases.formUnion(other.hostAliases)
            device.sources.formUnion(other.sources)
            device.capabilities.formUnion(other.capabilities)
            if device.kind == .other { device.kind = other.kind }
            if device.managementURL == nil { device.managementURL = other.managementURL }
        }
        // Manufacturer/model strings from UPnP are more useful than an AirPlay product code.
        if let detailed = ordered.first(where: { $0.source == .ssdp && !$0.model.isEmpty }) {
            device.model = detailed.model
        } else if device.model.isEmpty { device.model = ordered.first(where: { !$0.model.isEmpty })?.model ?? "" }
        return device
    }
}
