import XCTest
import Network
@testable import HomeSpeaker

/// Opt-in hardware tests with generated audio. Take over the explicitly selected receiver.
final class PhysicalCastTests: XCTestCase {
    func testControlSocketRecoveryKeepsTheExistingMediaSession() throws {
        guard let host = ProcessInfo.processInfo.environment["HOME_SPEAKER_TEST_RECOVERY_HOST"], !host.isEmpty else {
            throw XCTSkip("Set HOME_SPEAKER_TEST_RECOVERY_HOST to opt into a silent control-recovery test.")
        }
        let port = UInt16(ProcessInfo.processInfo.environment["HOME_SPEAKER_TEST_RECOVERY_PORT"] ?? "8009") ?? 8009
        let server = LiveAudioServer(sampleRate: 48_000, coordinatedStartup: true, preferIPv6: true)
        let device = CastDevice(id: "recovery-probe", name: "Recovery test speaker", model: "", host: host, port: port)
        let lock = NSLock()
        var connections: [NWConnection] = []
        let client = CastClient(device: device) { host, port, parameters in
            let socket = NWConnection(host: host, port: port, using: parameters)
            lock.lock(); connections.append(socket); lock.unlock()
            return socket
        }
        let connected = expectation(description: "Control connected")
        let playing = expectation(description: "Live media playing")
        let recovered = expectation(description: "Fresh timing on the replacement control socket")
        var stage = 0
        var originalSession: Int?
        var originalContent: String?
        var interruptedAt = Double.infinity
        var lastState = ""
        client.onError = { XCTFail($0) }
        client.onStatus = { status in
            lastState = status.playerState
            if stage == 0 { stage = 1; connected.fulfill() }
            if stage == 1, status.playerState == "PLAYING" {
                originalSession = status.mediaSessionID; originalContent = status.contentID
                stage = 2; playing.fulfill()
            } else if stage == 2, (status.positionSampledAt ?? 0) > interruptedAt {
                lock.lock(); let count = connections.count; lock.unlock()
                if count >= 2 {
                    XCTAssertEqual(status.mediaSessionID, originalSession, "Recovery must not LOAD another media session")
                    XCTAssertEqual(status.contentID, originalContent)
                    stage = 3; recovered.fulfill()
                }
            }
        }
        server.onReady = { print("PHYSICAL recovery source: \($0)"); client.playMacAudio(at: $0) }
        client.onProgress = { print("PHYSICAL recovery: \($0)") }
        let feed = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "PhysicalRecoveryPCM"))
        var frame = 0
        feed.schedule(deadline: .now(), repeating: .milliseconds(20))
        feed.setEventHandler {
            var samples = [Int16]()
            for _ in 0..<960 {
                let value = Int16(sin(Double(frame) * 2 * .pi * 440 / 48_000) * 24)
                samples.append(value); samples.append(value); frame += 1
            }
            server.append(samples.withUnsafeBytes { Data($0) })
        }
        client.connect(); wait(for: [connected], timeout: 10)
        try server.start()
        feed.resume()
        defer { feed.cancel(); client.cancelMacAudio(); server.stop(); client.disconnect() }
        wait(for: [playing], timeout: 15)
        guard stage == 2 else { return }
        lock.lock(); let originalSocket = try XCTUnwrap(connections.first); lock.unlock()
        interruptedAt = ProcessInfo.processInfo.systemUptime
        originalSocket.cancel()
        wait(for: [recovered], timeout: 12)
        guard stage == 3 else { return }
        let stable = expectation(description: "Playback stays active after control recovery")
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { stable.fulfill() }
        wait(for: [stable], timeout: 12)
        XCTAssertEqual(lastState, "PLAYING")
        lock.lock(); let count = connections.count; lock.unlock()
        XCTAssertEqual(count, 2)
        print("PHYSICAL control socket restored; mediaSessionId=\(originalSession ?? -1), no media reload")
    }

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
