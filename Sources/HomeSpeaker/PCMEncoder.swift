import AVFoundation

enum PCMEncoder {
    static func encode(_ buffer: AVAudioPCMBuffer) -> Data {
        guard buffer.format.channelCount == 2, let channels = buffer.floatChannelData else { return Data() }
        let frames = Int(buffer.frameLength)
        let isInterleaved = buffer.format.isInterleaved
        var pcm = Data(count: frames * 4)
        pcm.withUnsafeMutableBytes { raw in
            guard let samples = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for frame in 0..<frames {
                let left = channels[0][isInterleaved ? frame * 2 : frame]
                let right = isInterleaved ? channels[0][frame * 2 + 1] : channels[1][frame]
                samples[frame * 2] = quantize(left).littleEndian
                samples[frame * 2 + 1] = quantize(right).littleEndian
            }
        }
        return pcm
    }

    private static func quantize(_ sample: Float) -> Int16 {
        guard sample.isFinite else { return 0 }
        return Int16((max(-1, min(1, sample)) * 32767).rounded())
    }
}
