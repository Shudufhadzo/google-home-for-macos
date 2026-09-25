import AVFoundation
import CoreAudio
import Foundation
import os

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
// Lifecycle state is confined to lifecycle; cancellation is locked; signal state is callback-queue only.
final class SystemAudioTap: @unchecked Sendable {
    private let logger = Logger(subsystem: "za.shudu.homespeaker", category: "AudioCapture")
    private var audioFormat: AVAudioFormat?
    private var reportedSignal = false
    private let lifecycle = DispatchQueue(label: "HomeSpeaker.AudioLifecycle", qos: .userInitiated)
    private let cancellationLock = NSLock()
    private var cancelled = false
    private let queue = DispatchQueue(label: "HomeSpeaker.SystemAudioTap", qos: .userInitiated)
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProc: AudioDeviceIOProcID?
    private var sampleRate: Int = 48_000

    func prepare(source: CastAudioSource) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            lifecycle.async {
                do {
                    try self.checkCancellation()
                    try self.prepareResources(source: source)
                    continuation.resume(returning: self.sampleRate)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func startCapture(consume: @escaping (Data) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lifecycle.async {
                do {
                    try self.checkCancellation()
                    try self.startResources(consume: consume)
                    try self.checkCancellation()
                    continuation.resume()
                } catch {
                    self.stopResources()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop(completion: @escaping () -> Void = {}) {
        cancellationLock.lock()
        cancelled = true
        cancellationLock.unlock()
        lifecycle.async {
            self.stopResources()
            completion()
        }
    }

    private func checkCancellation() throws {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        if cancelled { throw CancellationError() }
    }

    private func prepareResources(source: CastAudioSource) throws {
        guard tapID == kAudioObjectUnknown else { return }
        do {
            let description = try source.tapDescription()
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
            self.audioFormat = audioFormat
            logger.notice("Prepared source=\(source.rawValue, privacy: .public), rate=\(self.sampleRate), interleaved=\(audioFormat.isInterleaved), mute=mutedWhenTapped")
        } catch {
            stopResources()
            throw error
        }
    }

    private func startResources(consume: @escaping (Data) -> Void) throws {
        guard let audioFormat, aggregateID != kAudioObjectUnknown else {
            throw AudioTapError.unavailable("Audio capture was not prepared.")
        }
        do {
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, queue) { [weak self] _, input, _, _, _ in
                guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, bufferListNoCopy: input, deallocator: nil) else { return }
                let pcm = PCMEncoder.encode(buffer)
                if !self.reportedSignal, pcm.contains(where: { $0 != 0 }) {
                    self.reportedSignal = true
                    self.logger.notice("Receiving non-silent stereo PCM while local playback is muted")
                }
                if !pcm.isEmpty { consume(pcm) }
            }, "Starting audio capture callback")
            try check(AudioDeviceStart(aggregateID, ioProc), "Starting system audio capture")
        } catch {
            stopResources()
            throw error
        }
    }

    private func stopResources() {
        let wasActive = tapID != kAudioObjectUnknown
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
        audioFormat = nil
        if wasActive { logger.notice("Capture released; local playback restored") }
    }

    deinit { stopResources() }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw AudioTapError.osStatus(step, status) }
    }
}
