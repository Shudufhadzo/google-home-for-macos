import XCTest
@testable import HomeCore

actor FixtureTransport: HomeHTTPTransport {
    var requests: [URLRequest] = []
    let status: Int
    init(status: Int = 200) { self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let text: String
        if request.url!.path.hasSuffix("api/states") {
            text = "[{\"entity_id\":\"light.desk\",\"state\":\"off\",\"attributes\":{\"friendly_name\":\"Desk light\",\"supported_color_modes\":[\"brightness\"]}},{\"entity_id\":\"light.desk\",\"state\":\"on\",\"attributes\":{}},{\"entity_id\":\"../../unsafe\",\"state\":\"on\",\"attributes\":{}}]"
        } else if request.url!.path.hasSuffix("api/services") {
            text = "[{\"domain\":\"light\",\"services\":{\"turn_on\":{},\"turn_off\":{}}}]"
        } else { text = "[]" }
        return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class HomeAssistantClientTests: XCTestCase {
    func testSnapshotAndDeviceCommandsUseAuthenticatedServiceEndpoints() async throws {
        let transport = FixtureTransport()
        let client = try HomeAssistantClient(baseURL: URL(string: "http://127.0.0.1:8123/ha")!, token: "fixture-token", transport: transport)
        let snapshot = try await client.snapshot()
        XCTAssertEqual(snapshot.entities.count, 1)
        XCTAssertEqual(snapshot.entities.first?.name, "Desk light")
        try await client.perform(.action(.turnOn), entity: snapshot.entities[0], services: snapshot.services)
        let requests = await transport.requests
        let post = try XCTUnwrap(requests.first(where: { $0.httpMethod == "POST" }))
        XCTAssertEqual(post.url?.path, "/ha/api/services/light/turn_on")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        XCTAssertEqual(try JSONDecoder().decode([String: JSONValue].self, from: XCTUnwrap(post.httpBody)), ["entity_id": .string("light.desk")])
        XCTAssertFalse(requests.contains { $0.httpMethod == "POST" && $0.url!.path.contains("/states") })
    }

    func testUnauthorizedConnectionProducesAnActionableError() async throws {
        let client = try HomeAssistantClient(baseURL: URL(string: "http://127.0.0.1:8123")!, token: "fixture-token", transport: FixtureTransport(status: 401))
        do { _ = try await client.snapshot(); XCTFail("Expected authorization failure") }
        catch { XCTAssertEqual(error as? HomeConnectionError, .unauthorized) }
    }

    func testUnsupportedCommandsNeverReachTheNetwork() async throws {
        let transport = FixtureTransport()
        let client = try HomeAssistantClient(baseURL: URL(string: "http://127.0.0.1:8123")!, token: "fixture-token", transport: transport)
        let snapshot = try await client.snapshot()
        do { try await client.perform(.action(.open), entity: snapshot.entities[0], services: snapshot.services); XCTFail("Expected unsupported control") }
        catch { XCTAssertEqual(error as? HomeConnectionError, .unsupportedControl) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }
}
