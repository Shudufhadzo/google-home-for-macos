import Foundation

public struct SSDPAdvertisement: Equatable, Sendable {
    public let id: String
    public let location: URL
    public let maxAge: TimeInterval

    public static func parse(_ data: Data) -> SSDPAdvertisement? {
        guard data.count <= 16_384, let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.first?.uppercased().hasPrefix("HTTP/1.1 200 ") == true else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        guard let rawLocation = headers["location"], let rawID = headers["usn"], rawID.count <= 512,
              rawID.lowercased().hasPrefix("uuid:"),
              let location = try? HomeEndpointPolicy.address(rawLocation, localOnly: true) else { return nil }
        let id = String(rawID.components(separatedBy: "::")[0].lowercased())
        var age: Double = 60
        if let cache = headers["cache-control"],
           let match = cache.range(of: "max-age\\s*=\\s*([0-9]+)", options: .regularExpression) {
            age = Double(cache[match].components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 60
        }
        return SSDPAdvertisement(id: "ssdp:\(id)", location: location, maxAge: min(max(age, 1), 120))
    }
}

/// Only the root device is read; embedded service/device names cannot overwrite it.
public struct UPnPDescription: Equatable, Sendable {
    public let name: String
    public let manufacturer: String
    public let model: String
    public let deviceType: String
    public let presentationURL: URL?

    public var kind: HomeDeviceKind {
        let type = deviceType.lowercased()
        if type.contains("internetgatewaydevice") { return .router }
        if type.contains("wlanaccesspoint") { return .extender }
        if type.contains("mediarenderer") || type.contains("mediaserver") { return .television }
        return .other
    }

    public static func parse(_ data: Data, location: URL) -> UPnPDescription? {
        guard data.count <= 256 * 1024 else { return nil }
        let reader = DescriptionReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), !reader.fields["friendlyName", default: ""].isEmpty else { return nil }
        var presentation: URL?
        if let path = reader.fields["presentationURL"],
           let resolved = URL(string: path, relativeTo: location)?.absoluteURL,
           let safe = try? HomeEndpointPolicy.address(resolved.absoluteString, localOnly: true),
           safe.host?.lowercased() == location.host?.lowercased() { presentation = safe }
        return UPnPDescription(name: reader.fields["friendlyName"] ?? "UPnP device",
                              manufacturer: reader.fields["manufacturer"] ?? "",
                              model: reader.fields["modelName"] ?? "",
                              deviceType: reader.fields["deviceType"] ?? "", presentationURL: presentation)
    }
}

private final class DescriptionReader: NSObject, XMLParserDelegate {
    var fields: [String: String] = [:]
    private var stack: [String] = []
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        stack.append(elementName); text = ""
        if stack.count > 24 { parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if text.count < 2_048 { text += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack == ["root", "device", elementName] {
            fields[elementName] = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        }
        _ = stack.popLast(); text = ""
    }
}
