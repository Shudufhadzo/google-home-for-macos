import Foundation
import HomeCore
import SystemConfiguration

@MainActor
final class HomeNetworkDiscovery: NSObject {
    static let serviceTypes = ["_home-assistant._tcp.", "_http._tcp.", "_https._tcp.",
                               "_hap._tcp.", "_matter._tcp.", "_matterc._udp.", "_airplay._tcp.", "_ipp._tcp."]
    var onUpdate: (([HomeDevice], String, String?, Bool) -> Void)?
    private var browsers: [NetServiceBrowser] = []
    private var services: [String: NetService] = [:]
    private var records: [String: HomeDevice] = [:]
    private var ssdp: SSDPSearch?
    private var lookups: [String: Task<Void, Never>] = [:]
    private var expirations: [String: Task<Void, Never>] = [:]
    private var completion: Task<Void, Never>?
    private var generation = UUID()
    private var scanning = false
    private var issue: String?
    private var interface: String?
    private let transport: any HomeHTTPTransport = HomeURLSessionTransport()

    func scan() {
        stop()
        generation = UUID()
        let run = generation
        records.removeAll(); issue = nil; scanning = true
        if let network = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            interface = network["PrimaryInterface"] as? String
            if let router = network["Router"] as? String, let url = HomeEndpointPolicy.localURL(host: router) {
                let device = HomeDevice(id: "gateway:\(router)", name: "Network gateway", kind: .router, source: .gateway,
                                        host: router, managementURL: url, state: "Current route",
                                        controlNote: "The gateway reported by macOS. Open its management page if this router offers one.")
                records[device.id] = device
            }
        }
        for type in Self.serviceTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self; browsers.append(browser)
            browser.searchForServices(ofType: type, inDomain: "local.")
        }
        let search = SSDPSearch()
        search.onData = { [weak self] data in
            Task { @MainActor [weak self] in guard let self, self.generation == run else { return }; self.receive(data) }
        }
        search.onError = { [weak self] reason in
            Task { @MainActor [weak self] in
                guard let self, self.generation == run else { return }
                self.issue = "UPnP discovery unavailable (\(reason)). Check the network and Local Network access."; self.publish()
            }
        }
        ssdp = search; search.start()
        completion = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard !Task.isCancelled, let self, self.generation == run else { return }
            self.scanning = false; self.publish()
        }
        publish()
    }

    func stop() {
        generation = UUID()
        browsers.forEach { $0.stop() }; browsers.removeAll()
        services.values.forEach { $0.stop() }; services.removeAll()
        ssdp?.stop(); ssdp = nil
        lookups.values.forEach { $0.cancel() }; lookups.removeAll()
        expirations.values.forEach { $0.cancel() }; expirations.removeAll()
        completion?.cancel(); completion = nil
        scanning = false; interface = nil
    }

    private func receive(_ data: Data) {
        guard let ad = SSDPAdvertisement.parse(data), lookups[ad.id] == nil,
              records[ad.id] == nil, lookups.count < 24, records.count < 128 else { return }
        let run = generation
        lookups[ad.id] = Task { [weak self, transport] in
            do {
                let (data, response) = try await transport.send(URLRequest(url: ad.location, timeoutInterval: 5))
                guard !Task.isCancelled, let self, self.generation == run, response.statusCode == 200,
                      let description = UPnPDescription.parse(data, location: ad.location) else { return }
                // A description URL is not a configuration page. Only open an explicit presentation URL.
                let device = HomeDevice(id: ad.id, name: description.name, kind: description.kind, source: .ssdp,
                                        model: [description.manufacturer, description.model].filter { !$0.isEmpty }.joined(separator: " · "),
                                        host: ad.location.host, managementURL: description.presentationURL, state: "Discovered",
                                        controlNote: description.presentationURL == nil ? "This device advertises UPnP. Add its management address or a compatible hub for controls." : "Configure this device in its own management page.")
                self.records[ad.id] = device; self.lookups.removeValue(forKey: ad.id); self.publish()
                self.expirations[ad.id] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(ad.maxAge * 1_000_000_000))
                    guard !Task.isCancelled, let self, self.generation == run else { return }
                    self.records.removeValue(forKey: ad.id); self.expirations.removeValue(forKey: ad.id); self.publish()
                }
            } catch {
                guard let self, self.generation == run else { return }
                self.lookups.removeValue(forKey: ad.id)
            }
        }
    }

    private func publish() {
        var values = Array(records.values)
        // Replace the generic route entry with a router that actually advertises the same address.
        let advertised = values
        values.removeAll { candidate in
            candidate.source == .gateway && advertised.contains {
                $0.source != .gateway && $0.host == candidate.host && $0.kind == .router
            }
        }
        // HTTP(S) advertisements often duplicate a UPnP description. Keep the richer device record.
        let richHosts = Set(values.filter { $0.source == .ssdp || $0.kind == .bridge }.compactMap(\.host))
        values.removeAll { $0.source == .bonjour && $0.kind == .other && $0.host.map(richHosts.contains) == true }
        values.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        onUpdate?(values, issue ?? (scanning ? "Discovering local devices…" : "Discovery complete. Devices appear when they advertise a supported service."), interface, scanning)
    }

    private func key(_ service: NetService) -> String { "bonjour:\(service.name)|\(service.type)|\(service.domain)" }

    private func resolved(_ service: NetService) {
        let id = key(service)
        guard services[id] === service, let hostname = service.hostName, (1...65535).contains(service.port) else { return }
        let host = service.addresses?.compactMap { data -> String? in
            data.withUnsafeBytes { bytes -> String? in
                guard data.count >= MemoryLayout<sockaddr_in>.size,
                      let address = bytes.baseAddress?.assumingMemoryBound(to: sockaddr.self), address.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(address, socklen_t(data.count), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
                return result == 0 ? String(cString: buffer) : nil
            }
        }.first ?? hostname
        let fields = service.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        func text(_ key: String) -> String? { fields[key].flatMap { String(data: $0, encoding: .utf8) } }
        let type = service.type
        var kind: HomeDeviceKind = .other
        var note = "A local service is advertised. Controls depend on the device's management page or a compatible hub."
        var url: URL?
        if type == "_home-assistant._tcp." {
            kind = .bridge; note = "Connect Home Assistant to bring its devices and controls into your home."
            let advertised = text("internal_url").flatMap { try? HomeEndpointPolicy.address($0, localOnly: true) }
            // Do not trust an advertisement that sends setup to a different machine.
            url = advertised.flatMap { ($0.host == hostname || $0.host == host || $0.host == hostname.trimmingCharacters(in: CharacterSet(charactersIn: "."))) ? $0 : nil }
                ?? HomeEndpointPolicy.localURL(host: host, port: service.port)
        } else if type == "_http._tcp." || type == "_https._tcp." {
            url = HomeEndpointPolicy.localURL(host: host, port: service.port, secure: type == "_https._tcp.")
            if let path = text("path"), path.hasPrefix("/"), !path.hasPrefix("//"), let base = url,
               let resolved = URL(string: path, relativeTo: base)?.absoluteURL,
               resolved.host == base.host { url = try? HomeEndpointPolicy.address(resolved.absoluteString, localOnly: true) }
        } else if type == "_airplay._tcp." { kind = .television; note = "AirPlay receiver discovered. Playback is available through macOS AirPlay." }
        else if type == "_hap._tcp." { kind = .accessory; note = "HomeKit accessory discovered. Pair it with a compatible HomeKit controller or Home Assistant." }
        else if type.hasPrefix("_matter") { kind = .accessory; note = "Matter service discovered. A commissioned compatible controller is required for control." }
        else if type == "_ipp._tcp." { note = "Printer discovered. Add it through macOS Printers & Scanners." }
        let device = HomeDevice(id: id, name: service.name, kind: kind, source: .bonjour,
                                model: text("md") ?? text("model") ?? type,
                                host: host, managementURL: url, state: "Discovered", controlNote: note)
        records[id] = device; publish()
    }
}

extension HomeNetworkDiscovery: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.browsers.contains(where: { $0 === browser }), self.services.count < 128 else { return }
            self.services[self.key(service)] = service; service.delegate = self; service.resolve(withTimeout: 6)
        }
    }
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.browsers.contains(where: { $0 === browser }) else { return }
            let id = self.key(service); self.services.removeValue(forKey: id)?.stop(); self.records.removeValue(forKey: id); self.publish()
        }
    }
    nonisolated func netServiceDidResolveAddress(_ service: NetService) { Task { @MainActor [weak self] in self?.resolved(service) } }
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        Task { @MainActor [weak self] in
            guard let self, self.browsers.contains(where: { $0 === browser }) else { return }
            self.issue = "Bonjour discovery is unavailable. Allow Local Network access in System Settings, then scan again."; self.publish()
        }
    }
}
