import AVFoundation
import AppKit
import CoreImage
import XCTest
@testable import HomeSpeaker

final class LiveAudioServerTests: XCTestCase {
    func testTVRenditionCarriesDecodedArtworkVideoAndSameAudioTimeline() throws {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
                                     samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<16 { for x in 0..<16 {
            let index = y * image.bytesPerRow + x * 3
            image.bitmapData![index] = 255
            image.bitmapData![index + 1] = 0
            image.bitmapData![index + 2] = 0
        } }
        let metadata = PlaybackMetadata(title: "Artwork delivery test", artist: "Home Manager QA", album: "Shared timeline",
                                        artwork: image.representation(using: .jpeg, properties: [:]))
        let ready = expectation(description: "Audio and TV video both ready")
        let server = LiveAudioServer(sampleRate: 48_000, coordinatedStartup: true, metadata: metadata, includeTVVideo: true)
        var url: URL?
        server.onReady = { address in
            var parts = URLComponents(url: address, resolvingAgainstBaseURL: false)!
            parts.host = "127.0.0.1"; url = parts.url; ready.fulfill()
        }
        server.onError = { XCTFail($0) }
        try server.start(); defer { server.stop() }
        wait(for: [ready], timeout: 8)
        let base = try XCTUnwrap(url).deletingLastPathComponent()
        var assets: [AVURLAsset] = []
        var files: [URL] = []
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        for directory in [base, base.appendingPathComponent("tv")] {
            let manifest = String(decoding: try fetch(directory.appendingPathComponent("live.m3u8")).0, as: UTF8.self)
            var movie = try fetch(directory.appendingPathComponent("init.mp4")).0
            for segment in manifest.split(separator: "\n").filter({ $0.hasSuffix(".m4s") }) {
                movie.append(try fetch(directory.appendingPathComponent(String(segment))).0)
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            try movie.write(to: file); files.append(file); assets.append(AVURLAsset(url: file))
        }
        XCTAssertTrue(assets[0].tracks(withMediaType: .video).isEmpty, "Speakers retain an audio-only stream")
        let audioRanges = try assets.map { asset in try XCTUnwrap(asset.tracks(withMediaType: .audio).first).timeRange }
        XCTAssertEqual(audioRanges[0].start.seconds, audioRanges[1].start.seconds, accuracy: 0.025, "Both AAC tracks share the same source origin")
        let track = try XCTUnwrap(assets[1].tracks(withMediaType: .video).first)
        XCTAssertEqual(track.naturalSize.width, 1280); XCTAssertEqual(track.naturalSize.height, 720)
        let reader = try AVAssetReader(asset: assets[1])
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        let cgImage = try XCTUnwrap(CIContext().createCGImage(CIImage(cvPixelBuffer: pixels), from: CGRect(x: 0, y: 0, width: 1280, height: 720)))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let coverPixel = try XCTUnwrap(bitmap.colorAt(x: 280, y: 360)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(coverPixel.redComponent, 0.8)
        XCTAssertLessThan(coverPixel.greenComponent, 0.2, "The actual decoded TV picture contains the cover, not a blank frame")
        if let path = ProcessInfo.processInfo.environment["HOME_MANAGER_POSTER_OUTPUT"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        reader.cancelReading()

        // A song change updates pictures inside the existing media timeline.
        // Replacing its URL/init segment would force both receivers to reconnect.
        let tv = base.appendingPathComponent("tv")
        let originalInit = try fetch(tv.appendingPathComponent("init.mp4")).0
        for y in 0..<16 { for x in 0..<16 {
            let index = y * image.bytesPerRow + x * 3
            image.bitmapData![index] = 0; image.bitmapData![index + 1] = 255
        } }
        server.updateNowPlaying(PlaybackMetadata(title: "Next song", artist: "Second artist", album: "Continuous playback",
                                                artwork: image.representation(using: .jpeg, properties: [:])))
        let updated = expectation(description: "Updated poster encoded in later fragments")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { updated.fulfill() }
        wait(for: [updated], timeout: 4)
        XCTAssertEqual(try fetch(tv.appendingPathComponent("init.mp4")).0, originalInit)
        let nextManifest = String(decoding: try fetch(tv.appendingPathComponent("live.m3u8")).0, as: UTF8.self)
        var continuousMovie = originalInit
        for segment in nextManifest.split(separator: "\n").filter({ $0.hasSuffix(".m4s") }) {
            continuousMovie.append(try fetch(tv.appendingPathComponent(String(segment))).0)
        }
        let nextFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try continuousMovie.write(to: nextFile); files.append(nextFile)
        let nextAsset = AVURLAsset(url: nextFile)
        let nextReader = try AVAssetReader(asset: nextAsset)
        let nextTrack = try XCTUnwrap(nextAsset.tracks(withMediaType: .video).first)
        let nextOutput = AVAssetReaderTrackOutput(track: nextTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        nextReader.add(nextOutput); XCTAssertTrue(nextReader.startReading())
        var lastSample: CMSampleBuffer?
        while let sample = nextOutput.copyNextSampleBuffer() { lastSample = sample }
        let last = try XCTUnwrap(lastSample)
        XCTAssertGreaterThan(CMSampleBufferGetPresentationTimeStamp(last).seconds, 2)
        let lastPixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(last))
        let lastImage = try XCTUnwrap(CIContext().createCGImage(CIImage(cvPixelBuffer: lastPixels), from: CGRect(x: 0, y: 0, width: 1280, height: 720)))
        let nextCover = try XCTUnwrap(NSBitmapImageRep(cgImage: lastImage).colorAt(x: 280, y: 360)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(nextCover.greenComponent, 0.8, "The next song's cover appears without replacing the stream")
        XCTAssertLessThan(nextCover.redComponent, 0.2)
    }
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

    func testTwoHTTPReceiversReadTheSameStartupAndAACSegments() throws {
        let ready = expectation(description: "Shared multi-receiver stream is ready")
        let server = LiveAudioServer(sampleRate: 48_000, coordinatedStartup: true)
        var streamURL: URL?
        server.onReady = { url in
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            parts.host = "127.0.0.1"; streamURL = parts.url; ready.fulfill()
        }
        server.onError = { XCTFail($0) }
        try server.start(); defer { server.stop() }
        wait(for: [ready], timeout: 5)
        let url = try XCTUnwrap(streamURL)
        let first = try fetch(url).0
        XCTAssertTrue(String(decoding: first, as: UTF8.self).contains("TIME-OFFSET=0,PRECISE=YES"))
        let segment = try XCTUnwrap(String(decoding: first, as: UTF8.self).split(separator: "\n").first { $0.hasSuffix(".m4s") })
        let base = url.deletingLastPathComponent()
        let reads = expectation(description: "Two independent HTTP sessions fetch identical media")
        reads.expectedFulfillmentCount = 2
        var media: [Data?] = [nil, nil]
        let lock = NSLock()
        let clients = [URLSession(configuration: .ephemeral), URLSession(configuration: .ephemeral)]
        defer { clients.forEach { $0.invalidateAndCancel() } }
        for (index, client) in clients.enumerated() {
            client.dataTask(with: base.appendingPathComponent(String(segment))) { data, response, error in
                XCTAssertNil(error); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                lock.lock(); media[index] = data; lock.unlock()
                reads.fulfill()
            }.resume()
        }
        wait(for: [reads], timeout: 5)
        XCTAssertFalse(try XCTUnwrap(media[0]).isEmpty)
        XCTAssertEqual(media[0], media[1], "Receivers consume the same encoded timeline, not independent captures")
        server.finishCoordinatedStartup()
        XCTAssertTrue(String(decoding: try fetch(url).0, as: UTF8.self).contains("TIME-OFFSET=-1.5,PRECISE=YES"))
    }

    func testCoordinatedStartupRetainsTheBeginningAndMemoryRemainsBounded() {
        var playlist = LiveAudioPlaylist(coordinatedStartup: true)
        playlist.initialization = Data([1])
        for _ in 0..<40 { playlist.append(Data([2]), duration: 0.5) }
        var text = String(decoding: playlist.manifest, as: UTF8.self)
        XCTAssertTrue(text.contains("#EXT-X-MEDIA-SEQUENCE:0"), "A slow second receiver can load the same starting point")
        XCTAssertTrue(text.contains("TIME-OFFSET=0,"))
        playlist.finishCoordinatedStartup()
        for _ in 40..<10_000 { playlist.append(Data([2]), duration: 0.5) }
        text = String(decoding: playlist.manifest, as: UTF8.self)
        XCTAssertEqual(playlist.segments.count, 129)
        XCTAssertEqual(text.components(separatedBy: "#EXTINF:").count - 1, 64)
        XCTAssertTrue(text.contains("#EXT-X-MEDIA-SEQUENCE:9936")); XCTAssertTrue(text.contains("TIME-OFFSET=-1.5,"))
        XCTAssertFalse(text.contains("#EXT-X-ENDLIST"))
    }

    func testFragmentsFromLastAdvertisedPlaylistSurviveAFullWindowAfterRemoval() {
        var playlist = LiveAudioPlaylist(coordinatedStartup: true)
        playlist.finishCoordinatedStartup()
        for _ in 0..<64 { playlist.append(Data([2]), duration: 0.5) }
        let advertised = playlist.segments.first!.number
        playlist.append(Data([2]), duration: 0.5)
        XCTAssertFalse(String(decoding: playlist.manifest, as: UTF8.self).contains("\n\(advertised).m4s\n"))
        for _ in 0..<64 { playlist.append(Data([2]), duration: 0.5) }
        XCTAssertTrue(playlist.segments.contains { $0.number == advertised }, "HLS clients get segment duration plus the longest advertised playlist to finish downloading")
        playlist.append(Data([2]), duration: 0.5)
        XCTAssertFalse(playlist.segments.contains { $0.number == advertised })
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
