import AVFoundation
import XCTest
@testable import HomeSpeaker

final class PCMEncoderTests: XCTestCase {
    func testStereoChannelsRemainIndependentInBothLayouts() throws {
        let left: [Float] = [0, 0.25, 0.5, 0.75, 1]
        let right: [Float] = [-1, -0.75, -0.5, -0.25, 0]
        let expected: [Int16] = [0, -32767, 8192, -24575, 16384, -16384, 24575, -8192, 32767, 0]
        for interleaved in [true, false] {
            let buffer = try makeBuffer(left: left, right: right, interleaved: interleaved)
            let encoded = PCMEncoder.encode(buffer)
            let actual = encoded.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            XCTAssertEqual(actual, expected, "Stereo sample order must survive interleaved=\(interleaved)")
        }
    }

    func testLeftAndRightTestTonesSurviveWithoutCrossTalk() throws {
        let rate = 48_000.0
        let left = (0..<4800).map { Float(sin(Double($0) * 2 * .pi * 440 / rate) * 0.8) }
        let right = (0..<4800).map { Float(sin(Double($0) * 2 * .pi * 997 / rate) * 0.5) }
        let buffer = try makeBuffer(left: left, right: right, interleaved: true)
        let samples = PCMEncoder.encode(buffer).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        for frame in left.indices {
            XCTAssertEqual(Float(samples[frame * 2]) / 32767, left[frame], accuracy: 1 / 32767)
            XCTAssertEqual(Float(samples[frame * 2 + 1]) / 32767, right[frame], accuracy: 1 / 32767)
        }
    }

    private func makeBuffer(left: [Float], right: [Float], interleaved: Bool) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)))
        buffer.frameLength = AVAudioFrameCount(left.count)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in left.indices {
            channels[0][interleaved ? frame * 2 : frame] = left[frame]
            channels[interleaved ? 0 : 1][interleaved ? frame * 2 + 1 : frame] = right[frame]
        }
        return buffer
    }
}
