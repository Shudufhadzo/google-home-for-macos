import AVFoundation
import CoreAudio
import Foundation

enum AudioTapError: LocalizedError {
    case unavailable(String)
    case osStatus(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .osStatus(let step, let code): return "\(step) failed (\(code)). Check System Audio Recording permission."
        }
    }
}

/// Captures the system mix without changing the Mac's normal output device.
@available(macOS 14.4, *)
final class SystemAudioTap {
    var onPCM: ((Data) -> Void)?
    private let queue = DispatchQueue(label: "HomeSpeaker.SystemAudioTap", qos: .userInitiated)
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProc: AudioDeviceIOProcID?
    private(set) var sampleRate: Int = 48_000

    func start() throws {
        guard tapID == kAudioObjectUnknown else { return }
        do {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.uuid = UUID()
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating audio tap")

            var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &format), "Reading audio tap format")
            guard format.mFormatID == kAudioFormatLinearPCM, format.mChannelsPerFrame == 2,
                  format.mBitsPerChannel == 32, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  let audioFormat = AVAudioFormat(streamDescription: &format) else {
                throw AudioTapError.unavailable("The Mac's system audio format is not supported for live casting.")
            }
            sampleRate = Int(format.mSampleRate.rounded())

            let outputID = AudioOutputManager.defaultOutput()
            var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            try check(AudioObjectGetPropertyData(outputID, &uidAddress, 0, nil, &uidSize, &uid), "Reading sound output")
            guard let outputUID = uid?.takeUnretainedValue() as String? else {
                throw AudioTapError.unavailable("No Mac sound output is available.")
            }
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Home Speaker audio tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Creating audio capture device")
            let isInterleaved = audioFormat.isInterleaved
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, queue) { [weak self] _, input, _, _, _ in
                guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, bufferListNoCopy: input, deallocator: nil),
                      let channels = buffer.floatChannelData else { return }
                let frames = Int(buffer.frameLength)
                guard frames > 0 else { return }
                var pcm = Data(count: frames * 4)
                pcm.withUnsafeMutableBytes { raw in
                    guard let samples = raw.bindMemory(to: Int16.self).baseAddress else { return }
                    for frame in 0..<frames {
                        let left = channels[0][frame]
                        let right = isInterleaved ? channels[0][frame * 2 + 1] : channels[1][frame]
                        samples[frame * 2] = Int16((max(-1, min(1, left)) * 32767).rounded())
                        samples[frame * 2 + 1] = Int16((max(-1, min(1, right)) * 32767).rounded())
                    }
                }
                self.onPCM?(pcm)
            }, "Starting audio capture callback")
            try check(AudioDeviceStart(aggregateID, ioProc), "Starting system audio capture")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProc {
                AudioDeviceStop(aggregateID, ioProc)
                AudioDeviceDestroyIOProcID(aggregateID, ioProc)
                self.ioProc = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    deinit { stop() }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw AudioTapError.osStatus(step, status) }
    }
}
