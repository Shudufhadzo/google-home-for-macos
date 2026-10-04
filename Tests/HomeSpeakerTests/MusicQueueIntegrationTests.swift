import AppKit
import XCTest
@testable import HomeSpeaker

/// Opt in with a real song already playing on this Mac. This deliberately seeks
/// to its end and advances one item in Music's existing queue; it edits no library.
final class MusicQueueIntegrationTests: XCTestCase {
    func testHeldSourcePreservesPositionAndAdvancesTheExistingQueue() async throws {
        guard ProcessInfo.processInfo.environment["HOME_MANAGER_TEST_MUSIC_QUEUE"] == "1" else {
            throw XCTSkip("Set HOME_MANAGER_TEST_MUSIC_QUEUE=1 with Music playing and a second song queued.")
        }
        let before = try snapshot()
        print("MUSIC QUEUE baseline: \(before)")
        XCTAssertTrue(before.playing, "Start a song on this Mac before running the opt-in test")
        guard before.playing else { return }
        let monitor = AppleMusicMonitor()
        let state = State()
        monitor.onTrack = { track in
            if let track, track.id != before.id || !track.isPlaying || track.duration - track.position < 5 {
                print("MUSIC QUEUE sample: id=\(track.id), position=\(track.position), duration=\(track.duration), playing=\(track.isPlaying), ended=\(track.atNaturalEnd)")
            }
            state.store(track)
        }
        monitor.onError = { state.fail($0) }
        monitor.start(coordinated: true)
        defer { monitor.stop() }
        let wasPlaying = try await monitor.holdForStartup()
        XCTAssertTrue(wasPlaying)
        let held = try snapshot()
        XCTAssertEqual(held.id, before.id)
        XCTAssertFalse(held.playing)
        XCTAssertEqual(held.position, before.position, accuracy: 2)
        let resumed = await withCheckedContinuation { continuation in
            monitor.resumeHeld(advance: nil) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(resumed)
        try await Task.sleep(nanoseconds: 750_000_000)
        let playing = try snapshot()
        XCTAssertEqual(playing.id, before.id)
        XCTAssertTrue(playing.playing)
        XCTAssertGreaterThanOrEqual(playing.position, held.position - 0.5, "Resume must preserve the held position")
        _ = try script("tell application id \"com.apple.Music\" to set player position to (duration of current track) - 4")
        var ended = false
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if state.track?.atNaturalEnd == true { ended = true; break }
        }
        XCTAssertTrue(ended, "Music must hold at its final fraction before the next queue item starts")
        if !ended { print("MUSIC QUEUE failed end snapshot: \(try snapshot())") }
        XCTAssertNil(state.error)
        guard ended else { return }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let stopped = try snapshot()
        XCTAssertEqual(stopped.id, before.id)
        XCTAssertFalse(stopped.playing)
        let advanced = await withCheckedContinuation { continuation in
            monitor.resumeHeld(advance: nil) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(advanced)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let next = try snapshot()
        XCTAssertNotEqual(next.id, before.id, "Music must advance its own existing queue after the held tail resumes")
        XCTAssertTrue(next.playing)
        print("MUSIC QUEUE: held/resumed the same position, held its final fraction, advanced the existing queue")
    }

    private func snapshot() throws -> (id: String, position: Double, playing: Bool) {
        let result = try script("tell application id \"com.apple.Music\" to return {persistent ID of current track, player position, player state is playing}")
        return (result.atIndex(1)?.stringValue ?? "", result.atIndex(2)?.doubleValue ?? 0, result.atIndex(3)?.booleanValue ?? false)
    }

    private func script(_ source: String) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { throw NSError(domain: "MusicQueueTest", code: error[NSAppleScript.errorNumber] as? Int ?? -1,
            userInfo: [NSLocalizedDescriptionKey: error[NSAppleScript.errorMessage] as? String ?? "Music scripting failed"] ) }
        return try XCTUnwrap(result)
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var value: MusicTrack?
        private var failure: String?
        var track: MusicTrack? { lock.lock(); defer { lock.unlock() }; return value }
        var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
        func store(_ track: MusicTrack?) { lock.lock(); value = track; lock.unlock() }
        func fail(_ error: String) { lock.lock(); failure = error; lock.unlock() }
    }
}
