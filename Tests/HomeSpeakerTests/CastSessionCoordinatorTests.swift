import XCTest
@testable import HomeSpeaker

private final class FixtureCastClient: CastControlling {
    var onStatus: ((CastStatus) -> Void)?
    var onError: ((String) -> Void)?
    var onProgress: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    var disconnected = false
    var loads: [(URL, Bool, Double?)] = []
    var playback: [Bool] = []
    var seeks: [Double] = []
    var volumes: [Double] = []
    var cancellations = 0
    func connect() {}
    func disconnect() { disconnected = true }
    func setVolume(_ level: Double) { volumes.append(level) }
    func setPlaying(_ playing: Bool) { playback.append(playing) }
    func stopPlayback() {}
    func skip(next: Bool) {}
    func playMacAudio(at url: URL, metadata: CastNowPlaying, autoplay: Bool, currentTime: Double?) { loads.append((metadata.streamURL(at: url), autoplay, currentTime)) }
    func cancelMacAudio() { cancellations += 1 }
    func requestMediaStatus() {}
    func seekLiveAudio(to time: Double) { seeks.append(time) }
}

final class CastSessionCoordinatorTests: XCTestCase {
    private let speaker = CastDevice(id: "speaker", name: "Home speaker", model: "L09G", host: "127.0.0.1", port: 8009)
    private let tv = CastDevice(id: "tv", name: "TV", model: "Chromecast", host: "127.0.0.2", port: 8009)
    private let stream = URL(string: "http://127.0.0.1:1234/live.m3u8")!

    private func status(content: String? = nil, state: String = "IDLE", position: Double = 10, sampled: Double = 100) -> CastStatus {
        var status = CastStatus()
        status.receiverAppID = "CC1AD845"; status.mediaSessionID = content == nil ? nil : 7
        status.contentID = content; status.playerState = state; status.isPlaying = state == "PLAYING"
        status.currentTime = position; status.positionSampledAt = sampled; status.playbackRate = 1
        status.supportsPause = true
        return status
    }

    @MainActor
    private func report(_ client: FixtureCastClient, _ status: CastStatus) async {
        let applied = expectation(description: "Receiver callback applied on main actor")
        client.onStatus?(status)
        Task { @MainActor in applied.fulfill() }
        await fulfillment(of: [applied], timeout: 1)
    }
    @MainActor
    func testSelectingATVRetainsTheSelectedSpeakerConnection() {
        var clients: [String: FixtureCastClient] = [:]
        let session = CastSessionCoordinator { device in
            let client = FixtureCastClient(); clients[device.id] = client; return client
        }
        session.select(CastDevice(id: "speaker", name: "Home speaker", model: "L09G", host: "127.0.0.1", port: 8009))
        session.select(CastDevice(id: "tv", name: "TV", model: "Chromecast", host: "127.0.0.2", port: 8009))
        XCTAssertEqual(Set(session.selectedDevices.map(\.id)), ["speaker", "tv"])
        XCTAssertFalse(clients["speaker"]!.disconnected, "Selecting the TV must keep the speaker as a simultaneous destination")
    }

    @MainActor
    func testOneSharedURLWaitsForEveryReceiverThenConfirmsAllPlaying() async throws {
        var clients: [String: FixtureCastClient] = [:]
        let session = CastSessionCoordinator(clientFactory: { device in
            let client = FixtureCastClient(); clients[device.id] = client; return client
        }, clock: { 100 })
        defer { session.disconnectAll() }
        session.select(speaker); session.select(tv)
        let a = try XCTUnwrap(clients[speaker.id]), b = try XCTUnwrap(clients[tv.id])
        await report(a, status())
        XCTAssertFalse(session.playMacAudio(at: stream, metadata: .macAudio), "Never silently cast to a connected subset")
        XCTAssertTrue(a.loads.isEmpty)
        await report(b, status())
        XCTAssertTrue(session.playMacAudio(at: stream, metadata: .macAudio))
        XCTAssertEqual(a.loads.first?.0, b.loads.first?.0)
        XCTAssertEqual(a.loads.first?.1, false); XCTAssertEqual(b.loads.first?.1, false)
        XCTAssertEqual(a.loads.first?.2, 0); XCTAssertEqual(b.loads.first?.2, 0)
        var prepared = 0, confirmed = 0
        session.onPrepared = { prepared += 1 }; session.onPlaybackConfirmed = { confirmed += 1 }
        let content = try XCTUnwrap(session.activeContentID)
        await report(a, status(content: content, state: "PAUSED"))
        XCTAssertTrue(a.playback.isEmpty); XCTAssertTrue(b.playback.isEmpty)
        await report(b, status(content: content, state: "PAUSED"))
        XCTAssertEqual(prepared, 1); XCTAssertEqual(a.playback, [true]); XCTAssertEqual(b.playback, [true])
        await report(a, status(content: content, state: "PLAYING"))
        XCTAssertEqual(confirmed, 0)
        await report(b, status(content: content, state: "PLAYING"))
        XCTAssertEqual(confirmed, 1)
        session.setPlaying(false)
        XCTAssertEqual(a.playback.last, false); XCTAssertEqual(b.playback.last, false)
        session.setVolume(0.4)
        XCTAssertEqual(a.volumes, [0.4]); XCTAssertEqual(b.volumes, [0.4])
        session.setVolume(0.2, deviceID: tv.id)
        XCTAssertEqual(a.volumes, [0.4]); XCTAssertEqual(b.volumes, [0.4, 0.2])
        session.cancelMacAudio()
        XCTAssertEqual(a.cancellations, 1); XCTAssertEqual(b.cancellations, 1)
        XCTAssertNil(session.activeContentID)
    }

    @MainActor
    func testEarlyAutoplayIsPausedAndAReceiverFailureStopsEveryLiveSession() async throws {
        var clients: [String: FixtureCastClient] = [:]
        let session = CastSessionCoordinator(clientFactory: { device in
            let client = FixtureCastClient(); clients[device.id] = client; return client
        }, clock: { 100 })
        defer { session.disconnectAll() }
        session.select(speaker); session.select(tv)
        let a = try XCTUnwrap(clients[speaker.id]), b = try XCTUnwrap(clients[tv.id])
        await report(a, status()); await report(b, status())
        session.playMacAudio(at: stream, metadata: .macAudio)
        let content = try XCTUnwrap(session.activeContentID)
        await report(a, status(content: content, state: "PLAYING"))
        XCTAssertEqual(a.playback, [false], "Hold an early player until the TV is prepared")
        var failure: String?
        session.onFailure = { failure = $0 }
        var foreign = status(content: "https://example.com/other", state: "PLAYING")
        foreign.receiverAppID = "ANOTHER_APP"
        await report(a, foreign)
        XCTAssertNil(session.activeContentID); XCTAssertNotNil(failure)
        XCTAssertEqual(a.cancellations, 1); XCTAssertEqual(b.cancellations, 1)
    }

    @MainActor
    func testGroupSelectionIsExclusiveAndRemovedConnectionCallbacksAreIgnored() async throws {
        var clients: [String: FixtureCastClient] = [:]
        let session = CastSessionCoordinator { device in
            let client = FixtureCastClient(); clients[device.id] = client; return client
        }
        defer { session.disconnectAll() }
        session.select(speaker); session.select(tv)
        let old = try XCTUnwrap(clients[speaker.id])
        let group = CastDevice(id: "group", name: "Whole home", model: "Google Cast Group", host: "127.0.0.3", port: 32000)
        session.select(group)
        XCTAssertTrue(old.disconnected); XCTAssertEqual(session.selectedDevices, [group])
        await report(old, status())
        XCTAssertFalse(session.connected.contains(speaker.id)); XCTAssertNil(session.statuses[speaker.id])
        session.select(speaker)
        XCTAssertEqual(session.selectedDevices, [speaker])
        await report(old, status())
        XCTAssertFalse(session.allConnected, "An old connection for the same device cannot make its replacement ready")
        await report(try XCTUnwrap(clients[speaker.id]), status())
        XCTAssertTrue(session.allConnected)
        session.playMacAudio(at: stream, metadata: .macAudio)
        XCTAssertEqual(clients[speaker.id]?.loads.last?.1, true, "Single receivers keep the previous startup behaviour")
        session.select(tv)
        XCTAssertEqual(session.selectedDevices, [speaker], "Do not change destinations under a running audio tap")
    }

    @MainActor
    func testDriftCorrectionRequiresThreeFreshRoundsAndHasACooldown() async throws {
        var now = 100.0
        var clients: [String: FixtureCastClient] = [:]
        let session = CastSessionCoordinator(clientFactory: { device in
            let client = FixtureCastClient(); clients[device.id] = client; return client
        }, clock: { now })
        defer { session.disconnectAll() }
        session.select(speaker); session.select(tv)
        let a = try XCTUnwrap(clients[speaker.id]), b = try XCTUnwrap(clients[tv.id])
        await report(a, status()); await report(b, status())
        session.playMacAudio(at: stream, metadata: .macAudio)
        let content = try XCTUnwrap(session.activeContentID)
        await report(a, status(content: content, state: "PAUSED")); await report(b, status(content: content, state: "PAUSED"))
        for round in 0..<3 {
            now = 100 + Double(round)
            var slow = status(content: content, state: "PLAYING", position: 10 + Double(round), sampled: now)
            slow.supportsSeek = true; slow.liveSeekableRange = 5...25
            var fast = slow; fast.currentTime = slow.currentTime! + 0.8
            await report(a, slow); await report(b, fast)
            if round < 2 { XCTAssertTrue(b.seeks.isEmpty) }
        }
        XCTAssertEqual(b.seeks, [12]); XCTAssertTrue(a.seeks.isEmpty)
        session.alignNow()
        XCTAssertEqual(b.seeks.count, 1, "A repeated manual click cannot bypass the correction cooldown")
        now += 4
        session.alignNow()
        XCTAssertEqual(b.seeks.count, 1, "Stale timing must never trigger seeking")
    }

    @MainActor
    func testUnexpectedSpeedAndDisconnectRetireCallbacksAndStopAllDestinations() async throws {
        for failBySpeed in [true, false] {
            var clients: [String: FixtureCastClient] = [:]
            let session = CastSessionCoordinator { device in
                let client = FixtureCastClient(); clients[device.id] = client; return client
            }
            defer { session.disconnectAll() }
            session.select(speaker); session.select(tv)
            let a = try XCTUnwrap(clients[speaker.id]), b = try XCTUnwrap(clients[tv.id])
            await report(a, status()); await report(b, status())
            session.playMacAudio(at: stream, metadata: .macAudio)
            let content = try XCTUnwrap(session.activeContentID)
            if failBySpeed {
                var wrong = status(content: content, state: "PLAYING"); wrong.playbackRate = 1.5
                await report(a, wrong)
            } else {
                a.onDisconnect?()
                let applied = expectation(description: "Disconnect callback applied")
                Task { @MainActor in applied.fulfill() }
                await fulfillment(of: [applied], timeout: 1)
            }
            XCTAssertNil(session.activeContentID); XCTAssertFalse(session.allConnected)
            XCTAssertTrue(a.disconnected); XCTAssertNotNil(session.errors[speaker.id])
            XCTAssertEqual(a.cancellations, 1); XCTAssertEqual(b.cancellations, 1)
            await report(a, status(content: content, state: "PLAYING"))
            XCTAssertFalse(session.allConnected, "Late playback cannot reconnect a retired failed client")
        }
    }

    @MainActor
    func testInitialIdleMediaDuringGroupLoadIsNotAStoppedPlayingSession() async throws {
        let client = FixtureCastClient()
        let session = CastSessionCoordinator { _ in client }
        defer { session.disconnectAll() }
        session.select(CastDevice(id: "group", name: "Home group", model: "Google Cast Group", host: "127.0.0.1", port: 32000))
        await report(client, status())
        session.playMacAudio(at: stream, metadata: .macAudio)
        let content = try XCTUnwrap(session.activeContentID)
        // Observed on the real Cast group: new media is first reported Idle.
        await report(client, status(content: content, state: "IDLE"))
        XCTAssertEqual(session.activeContentID, content, "A new item's initial Idle status must be allowed to load")
        await report(client, status(content: content, state: "BUFFERING"))
        await report(client, status(content: content, state: "PLAYING"))
        XCTAssertEqual(session.activeContentID, content)
        XCTAssertTrue(client.seeks.isEmpty, "The Mac does not seek or correct a group's member clocks")
        await report(client, status(content: content, state: "IDLE"))
        XCTAssertNil(session.activeContentID, "Idle after Playing must still release the stream")
    }

    @MainActor
    func testAStoppedMediaClockInPlayingStateCanFinishBuffering() async throws {
        let client = FixtureCastClient()
        let session = CastSessionCoordinator { _ in client }
        defer { session.disconnectAll() }
        session.select(speaker); await report(client, status())
        session.playMacAudio(at: stream, metadata: .macAudio)
        let content = try XCTUnwrap(session.activeContentID)
        var transitional = status(content: content, state: "PLAYING"); transitional.playbackRate = 0
        await report(client, transitional)
        XCTAssertEqual(session.activeContentID, content, "Cast media time may be stopped in any player state during buffering")
        await report(client, status(content: content, state: "PLAYING"))
        XCTAssertEqual(session.activeContentID, content, "The receiver must be allowed to reach normal advancing playback")
    }
}
