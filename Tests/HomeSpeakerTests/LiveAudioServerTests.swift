import Foundation
import XCTest
@testable import HomeSpeaker

final class LiveAudioServerTests: XCTestCase {
    func testHTTPStreamDeliversExactPCMBytesWithCorrectWaveFormat() throws {
        let ready = expectation(description: "HTTP listener ready")
        let disconnected = expectation(description: "Client disconnect ends the stream")
        let server = LiveAudioServer(sampleRate: 48_000)
        server.onError = { _ in disconnected.fulfill() }
        let pcm = Data((0..<19_200).map { UInt8($0 % 251) })
        var streamURL: URL?
        server.onReady = { url in
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.host = "127.0.0.1"
            streamURL = components.url
            ready.fulfill()
        }
        server.onReceiver = { server.append(pcm) }
        try server.start()
        defer { server.stop() }
        wait(for: [ready], timeout: 5)
        let url = try XCTUnwrap(streamURL)
        let artwork = Data([0xff, 0xd8, 0xff, 0xd9])
        server.setArtwork(artwork)
        let artworkReceived = expectation(description: "Artwork can be fetched separately from audio")
        URLSession.shared.dataTask(with: url.appendingPathExtension("jpg")) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(response?.mimeType, "image/jpeg")
            XCTAssertEqual(data, artwork)
            artworkReceived.fulfill()
        }.resume()
        wait(for: [artworkReceived], timeout: 5)
        let audioReceived = expectation(description: "Wave header and all PCM samples received")
        let reader = StreamReader(expectedCount: 44 + pcm.count) { audioReceived.fulfill() }
        let session = URLSession(configuration: .ephemeral, delegate: reader, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var streamComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        streamComponents.queryItems = [URLQueryItem(name: "track", value: "second-song")]
        session.dataTask(with: streamComponents.url!).resume()
        wait(for: [audioReceived], timeout: 5)
        XCTAssertEqual(reader.responseStatus, 200)
        XCTAssertEqual(String(data: reader.bytes.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertEqual(Array(reader.bytes.dropFirst(22).prefix(2)), [2, 0], "Stereo header")
        XCTAssertEqual(Array(reader.bytes.dropFirst(24).prefix(4)), [128, 187, 0, 0], "48 kHz header")
        XCTAssertEqual(Array(reader.bytes.dropFirst(34).prefix(2)), [16, 0], "16-bit header")
        XCTAssertEqual(Data(reader.bytes.dropFirst(44)), pcm, "HTTP chunking must preserve the waveform exactly")
        wait(for: [disconnected], timeout: 5)
    }
}

private final class StreamReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var bytes = Data()
    var responseStatus = 0
    private let expectedCount: Int
    private let complete: () -> Void
    private var fulfilled = false
    init(expectedCount: Int, complete: @escaping () -> Void) {
        self.expectedCount = expectedCount
        self.complete = complete
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        responseStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !fulfilled else { return }
        bytes.append(data)
        if bytes.count >= expectedCount {
            fulfilled = true
            complete()
            dataTask.cancel()
        }
    }
}
