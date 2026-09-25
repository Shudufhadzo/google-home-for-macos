import AVFoundation
import XCTest
@testable import HomeSpeaker

final class LiveAudioServerTests: XCTestCase {
    func testHTTPHLSContainsDecodableStereoAACAndStaysLiveWithoutCaptureCallbacks() throws {
        let ready = expectation(description: "A playable HLS window is ready")
        let receiver = expectation(description: "Receiver fetches a media segment")
        let server = LiveAudioServer(sampleRate: 48_000)
        server.onError = { XCTFail($0) }
        server.onReceiver = { receiver.fulfill() }
        var streamURL: URL?
        server.onReady = { url in
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.host = "127.0.0.1"
            streamURL = components.url
            ready.fulfill()
        }
        try server.start()
        defer { server.stop() }
        let feed = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "TestPCM"))
        var frame = 0
        feed.schedule(deadline: .now(), repeating: .milliseconds(20))
        feed.setEventHandler {
            var samples = [Int16]()
            for _ in 0..<960 {
                samples.append(Int16(sin(Double(frame) * 2 * .pi * 440 / 48_000) * 16_000))
                samples.append(Int16(sin(Double(frame) * 2 * .pi * 880 / 48_000) * 8_000))
                frame += 1
            }
            server.append(samples.withUnsafeBytes { Data($0) })
        }
        feed.resume()
        defer { feed.cancel() }
        wait(for: [ready], timeout: 10)
        let url = try XCTUnwrap(streamURL)
        XCTAssertEqual(url.pathExtension, "m3u8")
        feed.cancel()
        // Let the final tone packet reach the encoder before fetching its fragments.
        let settled = expectation(description: "Encoder callbacks settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        let manifest = try fetch(url).0
        let lines = String(decoding: manifest, as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("#EXT-X-TARGETDURATION:1"))
        let segments = lines.filter { $0.hasSuffix(".m4s") }
        XCTAssertGreaterThanOrEqual(segments.count, 3)
        XCTAssertLessThanOrEqual(segments.count, 6)
        let base = url.deletingLastPathComponent()
        var movie = try fetch(base.appendingPathComponent("init.mp4")).0
        for segment in segments { movie.append(try fetch(base.appendingPathComponent(segment)).0) }
        wait(for: [receiver], timeout: 2)

        XCTAssertEqual(try fetch(base.appendingPathComponent("../wrong/init.mp4")).1, 404)
        let cover = Data([0xff, 0xd8, 0xff, 0xd9])
        server.setArtwork(cover)
        XCTAssertEqual(try fetch(url.appendingPathExtension("jpg")).0, cover)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try movie.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let asset = AVURLAsset(url: file)
        let reader = try AVAssetReader(asset: asset)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var decodedFrames = 0
        var energy = [Double](repeating: 0, count: 2)
        while let sample = output.copyNextSampleBuffer() {
            let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
            let format = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description))
            XCTAssertEqual(format.pointee.mChannelsPerFrame, 2)
            XCTAssertEqual(format.pointee.mSampleRate, 48_000)
            decodedFrames += CMSampleBufferGetNumSamples(sample)
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var samples = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            let status = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            XCTAssertEqual(status, noErr)
            for (index, value) in samples.enumerated() { energy[index % 2] += Double(value * value) }
        }
        XCTAssertEqual(reader.status, .completed, "\(String(describing: reader.error))")
        XCTAssertGreaterThan(decodedFrames, 48_000)
        XCTAssertGreaterThan(energy[0], energy[1] * 3, "AAC must preserve independently captured stereo channels")
        XCTAssertGreaterThan(energy[1], 100, "Encoded output must contain audio")
        let resumed = expectation(description: "Silence keeps the live playlist advancing")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { resumed.fulfill() }
        wait(for: [resumed], timeout: 2)
        XCTAssertNotEqual(try fetch(url).0, manifest, "A paused app must not make the receiver abandon a stalled live playlist")
    }

    func testCanPrepareCastWhileMusicIsAlreadyPaused() throws {
        let ready = expectation(description: "Silent startup still prepares a playable stream")
        let server = LiveAudioServer(sampleRate: 48_000)
        server.onReady = { _ in ready.fulfill() }
        server.onError = { XCTFail($0) }
        try server.start()
        defer { server.stop() }
        wait(for: [ready], timeout: 5)
    }

    private func fetch(_ url: URL) throws -> (Data, Int) {
        let done = expectation(description: "HTTP \(url.lastPathComponent)")
        var result: (Data, Int)?
        var failure: Error?
        URLSession.shared.dataTask(with: url) { data, response, error in
            result = (data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0)
            failure = error
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        if let failure { throw failure }
        return try XCTUnwrap(result)
    }

    func testLiveWindowRemainsShortDuringLongCasts() {
        var playlist = LiveAudioPlaylist()
        playlist.initialization = Data([1])
        for _ in 0..<10_000 { playlist.append(Data([2]), duration: 0.5) }
        XCTAssertEqual(playlist.segments.count, 20)
        let text = String(decoding: playlist.manifest, as: UTF8.self)
        XCTAssertEqual(text.components(separatedBy: "#EXTINF:").count - 1, 6)
        XCTAssertTrue(text.contains("#EXT-X-MEDIA-SEQUENCE:9994"))
        XCTAssertFalse(text.contains("#EXT-X-ENDLIST"))
    }
}
