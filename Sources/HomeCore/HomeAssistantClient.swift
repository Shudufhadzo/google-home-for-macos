import Foundation

public protocol HomeHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// API credentials never follow HTTP redirects or enter shared caches/cookie storage.
public final class HomeURLSessionTransport: HomeHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 8 * 1024 * 1024 else {
            throw HomeConnectionError.invalidResponse
        }
        return (data, response)
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct HomeSnapshot: Sendable {
    public let entities: [HomeEntity]
    public let services: HomeServiceCatalog
    public init(entities: [HomeEntity], services: HomeServiceCatalog) { self.entities = entities; self.services = services }
}

public protocol HomeAssistantConnecting: Sendable {
    func snapshot() async throws -> HomeSnapshot
    func perform(_ command: HomeCommand, entity: HomeEntity, services: HomeServiceCatalog) async throws
}

public struct HomeAssistantClient: HomeAssistantConnecting, Sendable {
    public let baseURL: URL
    private let token: String
    private let transport: any HomeHTTPTransport

    public init(baseURL: URL, token: String, transport: any HomeHTTPTransport = HomeURLSessionTransport()) throws {
        self.baseURL = try HomeEndpointPolicy.address(baseURL.absoluteString)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else { throw HomeConnectionError.missingCredential }
        self.token = trimmed
        self.transport = transport
    }

    public func snapshot() async throws -> HomeSnapshot {
        async let statesData = request("api/states")
        async let servicesData = request("api/services")
        let (states, services) = try await (statesData, servicesData)
        let entities: [HomeEntity]
        let catalog: HomeServiceCatalog
        do {
            entities = try JSONDecoder().decode([HomeEntity].self, from: states)
            catalog = try HomeServiceCatalog.decode(services)
        } catch { throw HomeConnectionError.invalidResponse }
        // Ignore malformed entity IDs and duplicate server records rather than issuing unsafe paths.
        var seen = Set<String>()
        let valid = entities.filter {
            $0.id.range(of: "^[a-z_]+\\.[a-z0-9_]+$", options: .regularExpression) != nil && seen.insert($0.id).inserted
        }
        return HomeSnapshot(entities: valid.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, services: catalog)
    }

    public func perform(_ command: HomeCommand, entity: HomeEntity, services: HomeServiceCatalog) async throws {
        let call = try HomeControls.call(command, entity: entity, services: services)
        _ = try await request("api/services/\(call.domain)/\(call.service)", body: JSONEncoder().encode(call.data))
    }

    private func request(_ path: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 { throw HomeConnectionError.unauthorized }
            throw HomeConnectionError.http(response.statusCode)
        }
        return data
    }
}
