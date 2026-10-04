import AppKit
import CoreAudio
import Foundation

struct CastDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let model: String
    let host: String
    let port: UInt16

    var isGroup: Bool { model.caseInsensitiveCompare("Google Cast Group") == .orderedSame || id.hasPrefix("Google-Cast-Group-") }
}

@MainActor
final class SpeakerModel: NSObject, ObservableObject {
    @Published private(set) var devices: [CastDevice] = []
    @Published private(set) var selectedDevices: [CastDevice] = []
    @Published private(set) var receiverStatuses: [String: CastStatus] = [:]
    @Published private(set) var connectedDeviceIDs: Set<String> = []
    @Published private(set) var deviceErrors: [String: String] = [:]
    @Published private(set) var syncMessage = ""
    @Published private(set) var canAlign = false
    @Published private(set) var isConnected = false
    @Published private(set) var isCastingMacAudio = false
    @Published private(set) var isChangingTrack = false
    @Published private(set) var audioCaptureStarted = false
    @Published private(set) var audioSignalDetected = false
    @Published private(set) var isRestoringAudio = false
    @Published private(set) var volume = 0.5
    @Published private(set) var message = "Ready to scan."
    @Published private(set) var musicMessage = ""
    @Published private(set) var audioQuality = ""
    @Published private(set) var musicTrack: MusicTrack?
    @Published var castSource: CastAudioSource = .system
    @Published var includeAirPlay = false
    @Published var airPlayTimingOffset = 0.0 {
        didSet { updateAirPlayTiming() }
    }
    @Published private(set) var airPlayTimingMessage = ""
    @Published private var receiverStatus = CastStatus()
    let airPlay = AirPlayAudioPlayer()

    var selectedDevice: CastDevice? { selectedDevices.first }
    var destinationNames: String {
        (selectedDevices.map(\.name) + (includeAirPlay ? [airPlay.routeName ?? "AirPlay TV"] : [])).joined(separator: ", ")
    }
    var hasMultipleDestinations: Bool { selectedDevices.count > 1 }
    private var needsCoordinatedStart: Bool { hasMultipleDestinations || includeAirPlay }

    func destinationState(_ device: CastDevice) -> String {
        if let error = deviceErrors[device.id] { return error }
        guard connectedDeviceIDs.contains(device.id) else { return "Connecting…" }
        guard isCastingMacAudio else { return "Connected" }
        guard let liveURL, let status = receiverStatuses[device.id], status.contentID == liveURL.absoluteString else { return "Preparing…" }
        if let rate = status.playbackRate, status.playerState == "PLAYING" {
            if rate == 0 { return "Playing · waiting for advancing media time" }
            return "Playing · \(String(format: "%.2g", rate))× speed"
        }
        return status.playerState.capitalized
    }

    var trackTitle: String {
        if isCastingMacAudio { return musicTrack?.title ?? (castSource == .appleMusic ? "Apple Music" : "Mac audio") }
        return receiverStatus.title
    }
    var trackArtist: String {
        if isCastingMacAudio {
            return musicTrack.map { [$0.artist, $0.album].filter { !$0.isEmpty }.joined(separator: " · ") }
                ?? (castSource == .appleMusic ? "Start a song in Music" : "Live from this Mac")
        }
        return receiverStatus.artist
    }
    var isPlaying: Bool { isCastingMacAudio ? (musicTrack?.isPlaying ?? receiverStatus.isPlaying) : receiverStatus.isPlaying }
    var speakerArtworkURL: URL? { isCastingMacAudio ? nil : receiverStatus.artworkURL }
    var canControlPlayback: Bool { isCastingMacAudio ? musicTrack != nil && !isChangingTrack : !hasMultipleDestinations && isConnected && receiverStatus.mediaSessionID != nil }
    var canSkipNext: Bool { isCastingMacAudio ? musicTrack != nil && !isChangingTrack : !hasMultipleDestinations && isConnected && receiverStatus.supportsNext }
    var canSkipPrevious: Bool { isCastingMacAudio ? musicTrack != nil && !isChangingTrack : !hasMultipleDestinations && isConnected && receiverStatus.supportsPrevious }
    var canStop: Bool { isCastingMacAudio || canControlPlayback }

    private var browser: NetServiceBrowser?
    private var resolving: [String: NetService] = [:]
    private let sessions = CastSessionCoordinator()
    private var audioTap: SystemAudioTap?
    private var audioServer: LiveAudioServer?
    private var musicMonitor: AppleMusicMonitor?
    private var scanGeneration = 0
    private var castingID: UUID?
    private var liveURL: URL?
    private var castPlaybackConfirmed = false
    private var castReceiversConfirmed = false
    private var publishedTrackID: String?
    private var appliedMusicPlayback: Bool?
    private var audioStreamID = UUID()
    private var playbackAttemptID = UUID()
    private var resumeWhenPrepared: String?
    private var expectedMusicResumeID: String?
    private var castSampleRate = 48_000
    private let audioRelay = PCMStreamRelay()

    override init() {
        super.init()
        sessions.onUpdate = { [weak self] in self?.updateDestinations() }
        sessions.onPrepared = { [weak self] in
            guard let self else { return }
            if self.includeAirPlay, !self.airPlay.play(at: 0) {
                self.stopMacAudio(); self.message = "Choose an AirPlay output in Home Manager, then try again."; return
            }
            self.audioServer?.finishCoordinatedStartup()
            if let id = self.resumeWhenPrepared { self.resumeWhenPrepared = nil; self.musicMonitor?.resumePreparedTrack(id) }
        }
        sessions.onPlaybackConfirmed = { [weak self] in
            guard let self, self.isCastingMacAudio else { return }
            self.castReceiversConfirmed = true
            self.confirmSharedPlaybackIfReady()
        }
        sessions.onFailure = { [weak self] error in
            guard let self else { return }; self.stopMacAudio(); self.message = error
        }
        airPlay.onUpdate = { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.updateAirPlayTiming()
            guard self.isCastingMacAudio, self.includeAirPlay, let url = self.liveURL,
                  self.airPlay.currentURL == url else { return }
            if self.airPlay.isReady, self.airPlay.isAirPlayRouteSelected {
                self.sessions.markCompanionReady(contentID: url.absoluteString)
            }
            self.confirmSharedPlaybackIfReady()
        }
        airPlay.onError = { [weak self] error in
            guard let self, self.includeAirPlay, self.isCastingMacAudio else { return }
            self.stopMacAudio(); self.message = error
        }
    }

    private func updateDestinations() {
        selectedDevices = sessions.selectedDevices; receiverStatuses = sessions.statuses
        connectedDeviceIDs = sessions.connected; deviceErrors = sessions.errors
        receiverStatus = sessions.primaryStatus; isConnected = sessions.allConnected
        let levels = selectedDevices.compactMap { sessions.statuses[$0.id]?.volume }
        if !levels.isEmpty { volume = levels.reduce(0, +) / Double(levels.count) }
        syncMessage = sessions.syncMessage; canAlign = sessions.canAlign
        updateAirPlayTiming()
        // Capture preparation/restoration messages have their own lifecycle.
        if !isCastingMacAudio && !isRestoringAudio || sessions.activeContentID != nil {
            message = includeAirPlay && isCastingMacAudio && castReceiversConfirmed && !castPlaybackConfirmed
                ? "Speakers are ready; waiting for AirPlay playback on the TV…" : sessions.message
        }
    }

    private func confirmSharedPlaybackIfReady() {
        guard isCastingMacAudio, castReceiversConfirmed, !castPlaybackConfirmed,
              expectedMusicResumeID == nil,
              !includeAirPlay || (airPlay.currentURL == liveURL && airPlay.isPlaying) else { return }
        castPlaybackConfirmed = true; isChangingTrack = false
        audioServer?.finishCoordinatedStartup()
        // The startup barrier already sent PLAY to these receivers. A second
        // PLAY would seek multiple Cast receivers to the live edge while the
        // AirPlay item continues from the shared origin.
        if includeAirPlay, musicTrack?.isPlaying == true { appliedMusicPlayback = true }
        message = "Casting \(castSource.rawValue) to \(destinationNames). Local playback is muted."
        synchronizeMusicPlayback()
    }

    func start() {
        scanAgain()
    }

    func stop() {
        stopMacAudio()
        browser?.stop()
        browser = nil
        resolving.values.forEach { $0.stop() }; resolving.removeAll()
        sessions.disconnectAll()
        isConnected = false
    }

    func scanAgain() {
        scanGeneration += 1
        let generation = scanGeneration
        browser?.stop()
        devices.removeAll()
        resolving.values.forEach { $0.stop() }; resolving.removeAll()
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        browser.searchForServices(ofType: "_googlecast._tcp.", inDomain: "local.")
        if !isCastingMacAudio { message = "Searching for Cast speakers, TVs, and groups…" }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.scanGeneration == generation, self.devices.isEmpty else { return }
            self.message = "No Cast destinations found. Check Wi-Fi and Local Network access, then scan again."
        }
    }

    func connect(to device: CastDevice) {
        guard !isCastingMacAudio, !isRestoringAudio else { message = "Stop casting before changing destinations."; return }
        sessions.select(device)
    }

    func toggleDestination(_ device: CastDevice) {
        guard !isCastingMacAudio, !isRestoringAudio else { return }
        sessions.toggle(device)
    }
    func removeDestination(_ device: CastDevice) {
        guard !isCastingMacAudio, !isRestoringAudio else { return }; sessions.remove(device.id)
    }
    func alignDestinations() { sessions.alignNow() }

    private var airPlayAssessment: MixedPlaybackTiming.Assessment? {
        guard includeAirPlay, isCastingMacAudio, let liveURL,
              airPlay.currentURL == liveURL,
              selectedDevices.count == receiverStatuses.count else { return nil }
        return MixedPlaybackTiming.assess(statuses: receiverStatuses, contentID: liveURL.absoluteString,
                                          now: ProcessInfo.processInfo.systemUptime,
                                          airPlayPosition: airPlay.currentTime, airPlaySampledAt: airPlay.sampledAt,
                                          airPlayPlaying: airPlay.isPlaying, seekableRanges: airPlay.seekableRanges,
                                          offset: airPlayTimingOffset)
    }

    var canAlignAirPlay: Bool { airPlayAssessment?.target != nil }

    func alignAirPlay() {
        guard let target = airPlayAssessment?.target, airPlay.seek(to: target) else {
            airPlayTimingMessage = "Wait for fresh playback timing and an available live seek window."; return
        }
        airPlayTimingMessage = "TV timeline adjusted. Listen to both outputs; device sound processing can add delay."
    }

    private func updateAirPlayTiming() {
        guard includeAirPlay else { airPlayTimingMessage = ""; return }
        guard let assessment = airPlayAssessment else {
            airPlayTimingMessage = "Waiting for timing from the TV and all Cast destinations."; return
        }
        if let difference = assessment.difference {
            airPlayTimingMessage = "Reported TV timeline: \(String(format: "%+.2f", difference)) s relative to speakers. \(assessment.note)"
        } else { airPlayTimingMessage = assessment.note }
    }

    func togglePlayback() {
        if isCastingMacAudio { musicMonitor?.command(.playPause) }
        else if canControlPlayback { sessions.setPlaying(!isPlaying) }
    }

    func stopPlayback() {
        if isCastingMacAudio { stopMacAudio() }
        else if canStop { sessions.stopPlayback() }
    }

    func skipPrevious() {
        if isCastingMacAudio { changeMusicTrack(.previous) }
        else if canSkipPrevious { sessions.skip(next: false) }
    }

    func skipNext() {
        if isCastingMacAudio { changeMusicTrack(.next) }
        else if canSkipNext { sessions.skip(next: true) }
    }

    func setVolume(_ value: Double) {
        volume = value
        sessions.setVolume(value)
    }

    func setVolume(_ value: Double, for device: CastDevice) { sessions.setVolume(value, deviceID: device.id) }

    func retryMusicInfo() { musicMessage = ""; musicMonitor?.start() }

    func startMacAudio() {
        guard !isCastingMacAudio, !isRestoringAudio else { return }
        if includeAirPlay, castSource == .system {
            guard #available(macOS 26.0, *) else {
                message = "Choose Apple Music for combined AirPlay and Cast on this macOS version."; return
            }
        }
        guard isConnected else {
            message = "Connect every selected destination before sending Mac audio."
            return
        }
        let id = UUID()
        castingID = id
        playbackAttemptID = UUID()
        isCastingMacAudio = true
        castPlaybackConfirmed = false
        castReceiversConfirmed = false
        musicTrack = nil
        musicMessage = ""
        let source = castSource
        let tap = SystemAudioTap()
        audioSignalDetected = false
        tap.onSignal = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.castingID == id else { return }
                self.audioSignalDetected = true
            }
        }
        audioTap = tap
        message = "Preparing audio. Allow System Audio Recording if macOS asks…"
        Task { @MainActor [self] in
            do {
                let sampleRate = try await tap.prepare(source: source)
                guard castingID == id else { tap.stop(); return }
                castSampleRate = sampleRate
                audioQuality = "Stereo · \(String(format: "%.1f", Double(sampleRate) / 1000)) kHz · AAC 256 kbps"
                try await tap.startCapture { [audioRelay] pcm in audioRelay.append(pcm) }
                guard castingID == id else { tap.stop(); return }
                audioCaptureStarted = true
                try openAudioStream(track: nil, resumeMusic: false)
                guard source == .appleMusic else {
                    message = "Waiting for selected destinations. Local playback is muted."
                    return
                }
                let monitor = AppleMusicMonitor()
                monitor.onTrack = { [weak self] track in
                    Task { @MainActor [weak self] in
                        guard let self, self.castingID == id else { return }
                        if let track, track.id == self.expectedMusicResumeID, track.isPlaying {
                            self.expectedMusicResumeID = nil
                        }
                        guard !self.isChangingTrack else {
                            if track?.id == self.publishedTrackID {
                                self.musicTrack = track
                                self.confirmSharedPlaybackIfReady()
                            }
                            return
                        }
                        if let track, track.id != self.publishedTrackID {
                            self.changeMusicTrack(nil, observedTrack: track)
                        } else {
                            self.musicTrack = track
                            self.synchronizeMusicPlayback()
                        }
                        if track != nil { self.musicMessage = "" }
                    }
                }
                monitor.onError = { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, self.castingID == id else { return }
                        self.musicMessage = error
                    }
                }
                musicMonitor = monitor
                monitor.start()
                message = "Waiting for selected destinations. Local playback is muted."
            } catch {
                guard castingID == id else { return }
                stopMacAudio()
                message = error.localizedDescription
            }
        }
    }

    func stopMacAudio() {
        guard isCastingMacAudio else { return }
        castingID = nil
        playbackAttemptID = UUID()
        audioStreamID = UUID()
        isChangingTrack = false
        audioRelay.route(to: nil)
        isCastingMacAudio = false
        audioCaptureStarted = false
        audioSignalDetected = false
        isRestoringAudio = true
        audioTap?.stop { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRestoringAudio = false
                if self.message == "Stopping capture…" {
                    self.message = "Casting stopped. Local playback restored."
                }
            }
        }
        audioTap = nil
        audioServer?.stop()
        audioServer = nil
        musicMonitor?.stop()
        musicMonitor = nil
        musicTrack = nil
        publishedTrackID = nil
        appliedMusicPlayback = nil
        airPlay.stop()
        airPlayTimingMessage = ""
        musicMessage = ""
        audioQuality = ""
        liveURL = nil
        castPlaybackConfirmed = false
        castReceiversConfirmed = false
        resumeWhenPrepared = nil
        expectedMusicResumeID = nil
        sessions.cancelMacAudio(); updateDestinations()
        message = "Stopping capture…"
    }

    private func synchronizeMusicPlayback() {
        guard isCastingMacAudio, castSource == .appleMusic, castPlaybackConfirmed,
              !isChangingTrack, let track = musicTrack,
              appliedMusicPlayback != track.isPlaying else { return }
        if includeAirPlay, track.isPlaying, appliedMusicPlayback == false {
            airPlay.refreshRoute()
            guard airPlay.isAirPlayRouteSelected else {
                stopMacAudio(); message = "AirPlay disconnected while paused. Select the TV and start casting again."; return
            }
            // The live timeline advances during pauses. Reprepare both protocols
            // together at a fresh origin rather than resume different buffered times.
            changeMusicTrack(nil, observedTrack: track, rewindOverride: false)
            return
        }
        appliedMusicPlayback = track.isPlaying
        // The HLS timeline keeps advancing with silence while Music is paused.
        // Resume the existing session instead of loading a new player and waiting
        // for its startup buffer again.
        if includeAirPlay {
            if track.isPlaying {
                guard airPlay.play() else {
                    stopMacAudio(); message = "The AirPlay output could not resume. Select the TV and try again."; return
                }
            }
            else { airPlay.pause() }
        }
        sessions.setPlaying(track.isPlaying)
        message = track.isPlaying ? "Casting Apple Music. Local playback is muted."
                                  : "Apple Music and all destinations are paused."
    }

    private func changeMusicTrack(_ command: AppleMusicMonitor.Command?, observedTrack: MusicTrack? = nil, rewindOverride: Bool? = nil) {
        guard isCastingMacAudio, !isChangingTrack, let monitor = musicMonitor else { return }
        let resumeMusic = command != nil || (observedTrack ?? musicTrack)?.isPlaying == true
        let rewind = rewindOverride ?? (command != nil || publishedTrackID != nil)
        isChangingTrack = true
        castPlaybackConfirmed = false
        castReceiversConfirmed = false
        expectedMusicResumeID = nil
        audioStreamID = UUID()
        let transition = audioStreamID
        liveURL = nil
        audioRelay.route(to: nil)
        audioServer?.stop()
        audioServer = nil
        sessions.cancelMacAudio()
        airPlay.suspendForReplacement()
        message = "Changing song. Clearing every destination's buffered audio…"
        monitor.prepareTransition(command, rewind: rewind) { [weak self] track in
            Task { @MainActor [weak self] in
                guard let self, self.isCastingMacAudio, self.audioStreamID == transition else { return }
                guard let track else {
                    self.stopMacAudio()
                    self.message = "Could not prepare the next song. Start playback in Music and cast again."
                    return
                }
                self.musicTrack = track
                do { try self.openAudioStream(track: track, resumeMusic: resumeMusic) }
                catch { self.stopMacAudio(); self.message = error.localizedDescription }
            }
        }
    }

    private func openAudioStream(track: MusicTrack?, resumeMusic: Bool) throws {
        let streamID = UUID()
        audioStreamID = streamID
        castPlaybackConfirmed = false
        castReceiversConfirmed = false
        publishedTrackID = track?.id
        appliedMusicPlayback = nil
        resumeWhenPrepared = needsCoordinatedStart && resumeMusic ? track?.id : nil
        // Ignore the prepared song's paused snapshot until Music acknowledges
        // the requested resume; otherwise confirmation could pause both outputs
        // again before the asynchronous Music command has completed.
        expectedMusicResumeID = includeAirPlay && resumeMusic ? track?.id : nil
        let server = LiveAudioServer(sampleRate: castSampleRate, coordinatedStartup: needsCoordinatedStart)
        audioServer = server
        audioRelay.route { [weak server] in server?.append($0) }
        server.onReady = { [weak self, weak server] url in
            Task { @MainActor [weak self] in
                guard let self, let server, self.isCastingMacAudio, self.audioStreamID == streamID else { return }
                var metadata = CastNowPlaying.macAudio
                if let track {
                    var artworkURL: URL?
                    if let data = track.artwork, let bitmap = NSBitmapImageRep(data: data),
                       let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                        server.setArtwork(jpeg)
                        artworkURL = url.appendingPathExtension("jpg")
                    }
                    metadata = CastNowPlaying(id: track.id, title: track.title, artist: track.artist,
                                              album: track.album, artworkURL: artworkURL)
                }
                self.liveURL = metadata.streamURL(at: url)
                guard self.sessions.playMacAudio(at: url, metadata: metadata, waitForCompanion: self.includeAirPlay) else {
                    self.stopMacAudio(); self.message = "A destination disconnected before playback. Reconnect and try again."; return
                }
                if self.includeAirPlay {
                    self.airPlay.prepare(url: metadata.streamURL(at: url))
                    self.message = "Choose your TV using the AirPlay button in Home Manager. Both outputs wait until it is ready."
                } else {
                    self.message = resumeMusic ? "Preparing all destinations for the new song…" : "Starting Mac audio…"
                }
            }
        }
        server.onReceiver = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isCastingMacAudio, self.audioStreamID == streamID else { return }
                self.message = "Destinations are buffering the shared stream. Local playback is muted."
            }
        }
        server.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.isCastingMacAudio, self.audioStreamID == streamID else { return }
                self.stopMacAudio()
                self.message = error
            }
        }
        try server.start()
        // Start at the beginning of a fresh segmented timeline, preserving the song intro.
        if resumeMusic, !needsCoordinatedStart, let track { musicMonitor?.resumePreparedTrack(track.id) }
        watchPlaybackStartup()
    }

    private func watchPlaybackStartup() {
        let attempt = UUID()
        playbackAttemptID = attempt
        Task { @MainActor [weak self] in
            // Leave time to choose the TV in Apple's native route picker.
            let seconds: UInt64 = self?.includeAirPlay == true ? 90 : 25
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard let self, self.isCastingMacAudio, self.playbackAttemptID == attempt, !self.castPlaybackConfirmed else { return }
            self.stopMacAudio()
            self.message = "Not every destination started playback. Casting stopped. Check Wi-Fi and try again."
        }
    }


}

extension SpeakerModel: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            guard self.browser === browser, resolving.count < 128 else { return }
            let key = service.name + service.domain
            resolving[key] = service
            service.delegate = self
            service.resolve(withTimeout: 8)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        Task { @MainActor in
            guard self.browser === browser else { return }
            let key = service.name + service.domain
            resolving.removeValue(forKey: key)?.stop()
            devices.removeAll { $0.id == key }
            if let device = selectedDevices.first(where: { $0.id == key }) {
                let wasCasting = isCastingMacAudio
                if wasCasting { stopMacAudio() }
                sessions.remove(key)
                if wasCasting { message = "\(device.name) went offline. Casting stopped and Mac sound was restored." }
            }
        }
    }

    nonisolated func netServiceDidResolveAddress(_ service: NetService) {
        Task { @MainActor in
            let key = service.name + service.domain
            guard resolving[key] === service, let resolvedHost = service.hostName, service.port > 0, service.port <= 65535 else { return }
            let host = service.addresses?.compactMap { address -> String? in
                address.withUnsafeBytes { bytes -> String? in
                    guard address.count >= MemoryLayout<sockaddr_in>.size,
                          let pointer = bytes.baseAddress?.assumingMemoryBound(to: sockaddr.self),
                          pointer.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                    var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = getnameinfo(pointer, socklen_t(address.count), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST)
                    return result == 0 ? String(cString: name) : nil
                }
            }.first ?? resolvedHost
            let fields = service.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
            let name = fields["fn"].flatMap { String(data: $0, encoding: .utf8) } ?? service.name
            let model = fields["md"].flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let device = CastDevice(id: key, name: name, model: model, host: host, port: UInt16(service.port))
            devices.removeAll { $0.id == key }
            devices.append(device)
            devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if !isCastingMacAudio && !isConnected { message = "Found \(devices.count) Cast device\(devices.count == 1 ? "" : "s")." }
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        Task { @MainActor in
            guard self.browser === browser else { return }
            message = "Could not scan the local network. Check Local Network access in System Settings."
        }
    }
}

enum AudioOutputManager {
    static func defaultOutput() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return 0 }
        return id
    }

}
