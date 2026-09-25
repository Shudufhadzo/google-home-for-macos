import XCTest
@testable import HomeSpeaker

/// Opt-in, silent hardware test. Takes over the explicitly selected receiver.
final class PhysicalCastTests: XCTestCase {
    func testLongPauseAndDirectPlay() throws {
        guard let host = ProcessInfo.processInfo.environment["HOME_SPEAKER_TEST_HOST"], !host.isEmpty else {
            throw XCTSkip("Set HOME_SPEAKER_TEST_HOST to opt into taking over a physical Cast receiver.")
        }
        let server = LiveAudioServer(sampleRate: 48_000)
        let device = CastDevice(id: "probe", name: "Test speaker", model: "", host: host, port: 8009)
        let client = CastClient(device: device)
        let connected = expectation(description: "Connected")
        let playing = expectation(description: "Initial playing")
        let paused = expectation(description: "Paused")
        let resumed = expectation(description: "Resumed")
        var stage = 0
        var lastState = ""
        client.onError = { XCTFail($0) }
        client.onStatus = { status in
            if stage == 0 { stage = 1; connected.fulfill() }
            if lastState != status.playerState {
                print("PHYSICAL \(Date()) \(status.playerState)")
                lastState = status.playerState
            }
            if stage == 1, status.playerState == "PLAYING" { stage = 2; playing.fulfill() }
            else if stage == 2, status.playerState == "PAUSED" { stage = 3; paused.fulfill() }
            else if stage == 3, status.playerState == "PLAYING" { stage = 4; resumed.fulfill() }
        }
        server.onReady = { client.playMacAudio(at: $0) }
        client.connect()
        wait(for: [connected], timeout: 10)
        try server.start()
        defer { client.cancelMacAudio(); server.stop(); client.disconnect() }
        wait(for: [playing], timeout: 15)
        print("PHYSICAL PAUSE \(Date())")
        client.setPlaying(false)
        wait(for: [paused], timeout: 3)
        let held = expectation(description: "Hold a long pause")
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { held.fulfill() }
        wait(for: [held], timeout: 21)
        print("PHYSICAL RESUME \(Date())")
        client.setPlaying(true)
        wait(for: [resumed], timeout: 3)
        let stable = expectation(description: "Verify stable playback after resume")
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { stable.fulfill() }
        wait(for: [stable], timeout: 16)
        XCTAssertEqual(lastState, "PLAYING")
    }
}
