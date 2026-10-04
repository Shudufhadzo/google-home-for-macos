import AVFoundation
import AVKit
import CoreAudio
import SwiftUI

/// Plays the same live HLS timeline as the Cast receivers through a native AirPlay route.
/// The AVPlayer survives item replacements so the user's route selection can survive track changes.
@MainActor
final class AirPlayAudioPlayer: ObservableObject {
    enum State: Equatable {
        case idle, preparing, ready, waitingForRoute, buffering, playing, paused, failed
    }

    let player: AVPlayer
    var onUpdate: (() -> Void)?
    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?

    @Published private(set) var state: State = .idle
    @Published private(set) var message = "Choose the TV using the AirPlay button."
    @Published private(set) var isReady = false
    @Published private(set) var isExternalPlaybackActive = false
    @Published private(set) var isAirPlayRouteSelected = false
    @Published private(set) var routeName: String?
    @Published private(set) var currentTime: Double?
    @Published private(set) var sampledAt: TimeInterval?
    @Published private(set) var currentURL: URL?
    @Published var volume: Double = 0.33 {
        didSet {
            guard volume.isFinite else { volume = oldValue; return }
            let clamped = max(0, min(1, volume))
            if volume != clamped { volume = clamped }
            player.volume = Float(clamped)
        }
    }

    var isPlaying: Bool { state == .playing && player.rate.isFinite && abs(player.rate - 1) < 0.001 }
    var seekableRanges: [ClosedRange<Double>] {
        player.currentItem?.seekableTimeRanges.compactMap { value in
            let range = value.timeRangeValue
            let start = CMTimeGetSeconds(range.start), end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            return start.isFinite && end.isFinite && start < end ? start...end : nil
        } ?? []
    }
    var seekableRange: ClosedRange<Double>? { seekableRanges.last }

    private var observations: [NSKeyValueObservation] = []
    private var itemObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var routePolling: Task<Void, Never>?
    private var generation = UUID()
    private var seekGeneration = UUID()
    private var wantsPlayback = false

    init() {
        player = AVPlayer()
        player.allowsExternalPlayback = true
        player.volume = 0.33
        // Keep AVFoundation's buffering protection. Cross-protocol timing is only estimated.
        player.automaticallyWaitsToMinimizeStalling = true
        observations = [
            player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshRoute() }
            },
            player.observe(\.audioOutputDeviceUniqueID, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshRoute() }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshPlaybackState() }
            }
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentURL != nil, self.player.currentItem != nil else { return }
                let seconds = CMTimeGetSeconds(self.player.currentTime())
                self.currentTime = seconds.isFinite ? seconds : nil
                self.sampledAt = ProcessInfo.processInfo.systemUptime
                self.onUpdate?()
            }
        }
        // Core Audio's default route can change without AVPlayer's explicit UID changing.
        routePolling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                self?.refreshRoute()
            }
        }
        refreshRoute()
    }

    func prepare(url: URL) {
        clearItem(keepCurrentItem: true)
        let id = generation
        currentURL = url
        let item = AVPlayerItem(url: url)
        state = .preparing
        message = "Preparing the shared audio stream for AirPlay…"
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, self.generation == id, let item, self.player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    guard !self.isReady else { return }
                    self.isReady = true
                    self.refreshRoute()
                    guard self.generation == id else { return }
                    self.refreshPlaybackState()
                    guard self.generation == id else { return }
                    self.onReady?()
                    if self.generation == id { self.onUpdate?() }
                case .failed:
                    self.fail(item.error?.localizedDescription ?? "The shared audio stream could not be loaded.")
                default: break
                }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor [weak self] in
                guard let self, self.generation == id else { return }
                self.fail(error?.localizedDescription ?? "The AirPlay stream stopped unexpectedly.")
            }
        }
        player.replaceCurrentItem(with: item)
        onUpdate?()
    }

    /// Returns false until both the item and an AirPlay route are ready; never starts on Mac speakers.
    @discardableResult
    func play(at seconds: Double? = nil) -> Bool {
        if let seconds, !seconds.isFinite { return false }
        refreshRoute()
        guard isAirPlayRouteSelected else {
            state = .waitingForRoute
            message = "Choose the TV using the AirPlay button before starting playback."
            onUpdate?()
            return false
        }
        guard isReady else { return false }
        wantsPlayback = true
        if let seconds, seek(at: seconds) { return true }
        // Some live receivers expose no seekable window until playback begins.
        // Let HLS's shared start hint choose the position rather than fabricate an alignment.
        player.play()
        refreshPlaybackState()
        return true
    }

    func pause() {
        wantsPlayback = false
        seekGeneration = UUID()
        player.cancelPendingPrerolls()
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        refreshPlaybackState()
    }

    /// Only seeks inside the current live window; stale completions cannot restart another item.
    @discardableResult
    func seek(at seconds: Double) -> Bool {
        guard isReady, isAirPlayRouteSelected,
              let position = Self.clampedPosition(seconds, in: seekableRanges) else { return false }
        let itemID = generation, seekID = UUID()
        seekGeneration = seekID
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, finished, self.generation == itemID, self.seekGeneration == seekID else { return }
                self.refreshRoute()
                if self.wantsPlayback, self.isAirPlayRouteSelected { self.player.play() }
                self.refreshPlaybackState()
            }
        }
        return true
    }

    @discardableResult
    func seek(to seconds: Double) -> Bool { seek(at: seconds) }

    func stop() {
        clearItem()
        state = .idle
        message = "AirPlay stream stopped."
        refreshRoute()
        onUpdate?()
    }

    /// Retires the old stream without temporarily detaching its item. A nil item can
    /// make macOS tear down the user's AirPlay route before the replacement is ready.
    func suspendForReplacement() {
        clearItem(keepCurrentItem: true)
        state = .preparing
        message = "Preparing the next shared stream…"
        onUpdate?()
    }

    func refreshRoute() {
        let wasSelected = isAirPlayRouteSelected
        let oldName = routeName, oldExternal = isExternalPlaybackActive
        isExternalPlaybackActive = player.isExternalPlaybackActive
        let output = Self.outputRoute(uid: player.audioOutputDeviceUniqueID)
        isAirPlayRouteSelected = isExternalPlaybackActive || output.isAirPlay
        routeName = output.isAirPlay ? output.name : (isExternalPlaybackActive ? "AirPlay destination" : nil)
        if wasSelected, !isAirPlayRouteSelected, wantsPlayback {
            wantsPlayback = false
            seekGeneration = UUID()
            player.pause()
            state = .waitingForRoute
            message = "AirPlay disconnected. Choose the TV again to resume."
            onError?(message)
        }
        if wasSelected != isAirPlayRouteSelected || oldName != routeName || oldExternal != isExternalPlaybackActive {
            refreshPlaybackState()
            onUpdate?()
        }
    }

    static func clampedPosition(_ seconds: Double, in ranges: [ClosedRange<Double>]) -> Double? {
        guard seconds.isFinite else { return nil }
        // Leave a small margin at the moving live edge to avoid immediately falling outside it.
        return ranges.compactMap { range -> Double? in
            guard range.lowerBound.isFinite, range.upperBound.isFinite, range.lowerBound >= 0,
                  range.upperBound - range.lowerBound > 0.1 else { return nil }
            return max(range.lowerBound, min(seconds, range.upperBound - 0.05))
        }.min { abs($0 - seconds) < abs($1 - seconds) }
    }

    private func refreshPlaybackState() {
        guard player.currentItem != nil, state != .failed else { return }
        if !isReady { state = .preparing }
        else if !isAirPlayRouteSelected {
            state = .waitingForRoute
            message = "Stream ready. Choose the TV using the AirPlay button."
        } else if wantsPlayback {
            state = player.timeControlStatus == .playing ? .playing : .buffering
            message = state == .playing ? "AirPlay is playing the shared stream. Check the TV's sound." : "AirPlay is buffering…"
        } else {
            state = currentTime == nil ? .ready : .paused
            message = "AirPlay route selected. Shared stream ready."
        }
        onUpdate?()
    }

    private func fail(_ error: String) {
        guard state != .failed else { return }
        wantsPlayback = false
        player.pause()
        state = .failed
        isReady = false
        let failureMessage = "AirPlay: \(error)"
        message = failureMessage
        onUpdate?()
        onError?(failureMessage)
    }

    private func clearItem(keepCurrentItem: Bool = false) {
        generation = UUID()
        seekGeneration = UUID()
        wantsPlayback = false
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        itemObservation = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        if !keepCurrentItem { player.replaceCurrentItem(with: nil) }
        isReady = false
        currentTime = nil
        sampledAt = nil
        currentURL = nil
    }

    private static func outputRoute(uid: String?) -> (isAirPlay: Bool, name: String?) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let result: OSStatus
        if let uid {
            address.mSelector = kAudioHardwarePropertyTranslateUIDToDevice
            var qualifier = uid as CFString
            result = withUnsafePointer(to: &qualifier) { pointer in
                AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
            }
        } else {
            result = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device)
        }
        guard result == noErr, device != kAudioObjectUnknown else { return (false, nil) }
        address.mSelector = kAudioDevicePropertyTransportType
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeAirPlay else { return (false, nil) }
        address.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<CFString?>.size)
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        return (true, name?.takeUnretainedValue() as String?)
    }

    deinit {
        routePolling?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        player.pause()
    }
}

/// macOS supplies discovery, pairing, and route selection for this exact player instance.
struct AirPlayRoutePicker: NSViewRepresentable {
    let player: AirPlayAudioPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player.player
        view.delegate = context.coordinator
        view.isRoutePickerButtonBordered = true
        view.setAccessibilityLabel("Choose AirPlay TV or speaker")
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        view.player = player.player
        context.coordinator.owner = player
    }

    func makeCoordinator() -> Coordinator { Coordinator(owner: player) }

    @MainActor
    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        weak var owner: AirPlayAudioPlayer?
        init(owner: AirPlayAudioPlayer) { self.owner = owner }
        nonisolated func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            Task { @MainActor [weak self] in self?.owner?.refreshRoute() }
        }
    }
}
