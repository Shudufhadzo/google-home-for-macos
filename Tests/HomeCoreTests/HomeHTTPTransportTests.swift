import Network
import XCTest
@testable import HomeCore

private final class FixtureHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "home-manager.http-test")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    let response: String
    init(response: String) throws { listener = try NWListener(using: .tcp, on: .any); self.response = response }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                if case .ready = state, let port = self?.listener.port { resumed = true; continuation.resume(returning: port.rawValue) }
                else if case .failed(let error) = state { resumed = true; continuation.resume(throwing: error) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }; self.connections.append(connection)
                connection.start(queue: self.queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [response = self.response] _, _, _, _ in
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel(); queue.sync { connections.forEach { $0.cancel() }; connections.removeAll() } }
}

final class HomeHTTPTransportTests: XCTestCase {
    func testRealHTTPTransportReadsLocalResponse() async throws {
        let body = "{\"message\":\"fixture\"}"
        let server = try FixtureHTTPServer(response: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        let port = try await server.start(); defer { server.stop() }
        let transport = HomeURLSessionTransport()
        let (data, response) = try await transport.send(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/")!))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), body)
    }

    func testAuthenticatedRequestsDoNotFollowRedirects() async throws {
        // The redirect is reachable, but must be returned to the caller without forwarding a token.
        let server = try FixtureHTTPServer(response: "HTTP/1.1 302 Found\r\nLocation: /other\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        let port = try await server.start(); defer { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/states")!)
        request.setValue("Bearer fixture-only", forHTTPHeaderField: "Authorization")
        let (_, response) = try await HomeURLSessionTransport().send(request)
        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(response.url?.path, "/api/states")
    }
}
