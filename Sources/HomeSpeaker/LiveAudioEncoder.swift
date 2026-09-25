import AVFoundation
import UniformTypeIdentifiers

/// Native AAC encoder and fragmented MP4 muxer. Called only on the stream queue.
final class LiveAudioEncoder: NSObject, AVAssetWriterDelegate {
    var onSegment: ((Data, Double?) -> Void)?
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let format: CMAudioFormatDescription
    private let sampleRate: Int32
    private var frames: Int64 = 0

    init(sampleRate: Int) throws {
        self.sampleRate = Int32(sampleRate)
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        let result = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        guard result == noErr, let description else { throw Self.failure("Could not describe captured audio (\(result)).") }
        format = description
        writer = AVAssetWriter(contentType: .mpeg4Movie)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000
        ], sourceFormatHint: description)
        input.expectsMediaDataInRealTime = true
        super.init()
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 0.5, preferredTimescale: self.sampleRate)
        writer.initialSegmentStartTime = .zero
        writer.delegate = self
        guard writer.canAdd(input) else { throw Self.failure("AAC streaming is unavailable.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Self.failure("Could not start AAC encoding.") }
        writer.startSession(atSourceTime: .zero)
    }

    /// False means backpressure; the caller retains PCM in its bounded FIFO.
    func append(_ pcm: Data) throws -> Bool {
        guard writer.status == .writing else { throw writer.error ?? Self.failure("Audio encoder stopped.") }
        guard input.isReadyForMoreMediaData else { return false }
        guard !pcm.isEmpty, pcm.count % 4 == 0 else { return true }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: pcm.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: pcm.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw Self.failure("Could not allocate audio packet (\(status)).") }
        status = pcm.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: pcm.count) }
        guard status == noErr else { throw Self.failure("Could not copy audio packet (\(status)).") }
        let count = pcm.count / 4
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: CMTime(value: frames, timescale: sampleRate), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var size = 4
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw Self.failure("Could not create audio samples (\(status)).") }
        guard input.append(sample) else { throw writer.error ?? Self.failure("AAC encoder rejected audio.") }
        frames += Int64(count)
        return true
    }

    func stop() { writer.cancelWriting() }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        onSegment?(data, segmentType == .initialization ? nil : segmentReport?.trackReports.first?.duration.seconds ?? 0.5)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "HomeSpeaker.AudioEncoder", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
