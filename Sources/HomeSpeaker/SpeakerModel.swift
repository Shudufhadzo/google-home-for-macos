import AppKit
import CoreAudio
import Foundation
import OSLog

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
    var isPlaying: Bool { isCastingMacAudio ? (musicSourceHeld ? resumeSourceAfterAlignment : (musicTrack?.isPlaying ?? receiverStatus.isPlaying)) : receiverStatus.isPlaying }
    var speakerArtworkURL: URL? { isCastingMacAudio ? nil : receiverStatus.artworkURL }
    var canControlPlayback: Bool { isCastingMacAudio ? musicTrack != nil : !hasMultipleDestinations && isConnected && receiverStatus.mediaSessionID != nil }
    var canSkipNext: Bool { isCastingMacAudio ? musicTrack != nil : !hasMultipleDestinations && isConnected && receiverStatus.supportsNext }
    var canSkipPrevious: Bool { isCastingMacAudio ? musicTrack != nil : !hasMultipleDestinations && isConnected && receiverStatus.supportsPrevious }
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
    private var airPlayURL: URL?
    private var castPlaybackConfirmed = false
    private var castReceiversConfirmed = false
    private var publishedTrackID: String?
    private var appliedMusicPlayback: Bool?
    private var audioStreamID = UUID()
    private var playbackAttemptID = UUID()
    private var castSampleRate = 48_000
    private let audioRelay = PCMStreamRelay()
    private let logger = Logger(subsystem: "za.shudu.homespeaker", category: "SharedPlayback")
    private var activity: NSObjectProtocol?
    private var mixedDrift = MixedDriftController()
    private var lastTimingLog = -Double.infinity
    private var alignmentWindow = PlaybackAlignmentWindow()
    private var alignmentRevision = UUID()
    private var quietFloor: Double?
    private var musicSourceHeld = false
    private var resumeSourceAfterAlignment = false
    private var pendingAdvance: AppleMusicMonitor.Command?
    private var completingAlignment = false

    override init() {
        super.init()
        sessions.onUpdate = { [weak self] in self?.updateDestinations() }
        sessions.onPrepared = { [weak self] in
            guard let self else { return }
            self.logger.notice("Shared startup ready; anchor=\(self.sessions.sharedStartPosition ?? 0)")
            if self.includeAirPlay, !self.airPlay.play() {
                self.stopMacAudio(); self.message = "Choose an AirPlay output in Home Manager, then try again."; return
            }
            self.audioServer?.finishCoordinatedStartup()
        }
        sessions.onPlaybackConfirmed = { [weak self] in
            guard let self, self.isCastingMacAudio else { return }
            self.castReceiversConfirmed = true
            self.confirmSharedPlaybackIfReady()
        }
        sessions.onFailure = { [weak self] error in
            guard let self else { return }; self.stopMacAudio(reason: error); self.message = error
        }
        airPlay.onUpdate = { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.updateAirPlayTiming()
            guard self.isCastingMacAudio, self.includeAirPlay, let url = self.liveURL,
                  self.airPlay.currentURL == self.airPlayURL else { return }
            if self.airPlay.isReady, self.airPlay.isAirPlayRouteSelected {
                self.sessions.markCompanionReady(contentID: url.absoluteString, seekableRanges: self.airPlay.seekableRanges)
            }
            self.confirmSharedPlaybackIfReady()
            self.updatePlaybackAlignment()
        }
        airPlay.onError = { [weak self] error in
            guard let self, self.includeAirPlay, self.isCastingMacAudio else { return }
            self.stopMacAudio(reason: error); self.message = error
        }
        airPlay.onPlaybackRequest = { [weak self] playing in
            guard let self, self.isCastingMacAudio, self.includeAirPlay else { return }
            if self.musicTrack != nil {
                if self.isPlaying != playing { self.togglePlayback() }
            } else {
                if playing { _ = self.airPlay.play() } else { self.airPlay.pause() }
                self.sessions.setPlaying(playing)
            }
        }
        airPlay.onRouteInterrupted = { [weak self] in
            guard let self, self.includeAirPlay, self.isCastingMacAudio else { return }
            self.sessions.setPlaying(false)
            self.message = "TV route interrupted; holding both outputs while AirPlay reconnects…"
        }
        airPlay.onRouteRestored = { [weak self] in
            guard let self, self.includeAirPlay, self.isCastingMacAudio else { return }
            let anchor = self.sessions.liveAnchor.flatMap { target in
                self.airPlay.seekableRanges.contains(where: { $0.contains(target) }) ? target : nil
            }
            self.mixedDrift.reset()
            if self.airPlay.play(at: anchor) { self.sessions.resumeShared(at: anchor) }
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
        updatePlaybackAlignment()
        // Capture preparation/restoration messages have their own lifecycle.
        if !musicSourceHeld && (!isCastingMacAudio && !isRestoringAudio || sessions.activeContentID != nil) {
            message = includeAirPlay && isCastingMacAudio && castReceiversConfirmed && !castPlaybackConfirmed
                ? "Speakers are ready; waiting for AirPlay playback on the TV…" : sessions.message
        }
    }

    private func confirmSharedPlaybackIfReady() {
        guard isCastingMacAudio, castReceiversConfirmed, !castPlaybackConfirmed,
              !includeAirPlay || (airPlay.currentURL == airPlayURL && airPlay.isPlaying) else { return }
        castPlaybackConfirmed = true
        logger.notice("Shared playback confirmed on every destination")
        audioServer?.finishCoordinatedStartup()
        // The startup barrier already sent PLAY to these receivers. A second
        // PLAY would seek multiple Cast receivers to the live edge while the
        // AirPlay item continues from the shared origin.
        if needsCoordinatedStart {
            mixedDrift.reset()
            alignmentWindow.begin(at: ProcessInfo.processInfo.systemUptime)
            logger.notice("Opening bounded startup alignment window")
        }
        if includeAirPlay, musicTrack?.isPlaying == true, !musicSourceHeld { appliedMusicPlayback = true }
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
              airPlay.currentURL == airPlayURL,
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
            let error = difference - airPlayTimingOffset
            airPlayTimingMessage = "Reported TV timing error: \(String(format: "%+.0f", error * 1000)) ms. \(assessment.note)"
            if error < -MixedDriftController.tolerance, assessment.castTarget == nil {
                airPlayTimingMessage = "Reported TV timing error: \(String(format: "%+.0f", error * 1000)) ms. The Cast destination has not exposed a live seek window for automatic alignment."
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastTimingLog >= 5 {
                lastTimingLog = now
                let seek = receiverStatuses.values.map { "seek=\($0.supportsSeek), range=\(String(describing: $0.liveSeekableRange))" }.joined(separator: "; ")
                logger.notice("Timing error=\(error * 1000) ms, confirmed=\(self.castPlaybackConfirmed), AirPlay=\(String(describing: self.airPlay.state), privacy: .public), TV time=\(self.airPlay.currentTime ?? -1), Cast time=\(self.receiverStatus.currentTime ?? -1), Cast target=\(assessment.castTarget ?? -1), Cast \(seek, privacy: .public)")
            }
        } else { airPlayTimingMessage = assessment.note }
    }

    private func updatePlaybackAlignment() {
        guard isCastingMacAudio, castPlaybackConfirmed, !completingAlignment,
              alignmentWindow.phase != .inactive, let liveURL else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var positions: [String: Double] = [:], samples: [String: Double] = [:]
        var ranges: [ClosedRange<Double>] = []
        for device in selectedDevices {
            guard let status = receiverStatuses[device.id], status.contentID == liveURL.absoluteString,
                  status.receiverAppID == "CC1AD845", status.mediaSessionID != nil,
                  status.playerState == "PLAYING", status.playbackRate == 1,
                  let position = status.estimatedPosition(at: now), let sampled = status.positionSampledAt else { continue }
            positions[device.id] = position; samples[device.id] = sampled
            if status.supportsSeek, let range = status.liveSeekableRange { ranges.append(range) }
        }
        let castPositions = Array(positions.values)
        let castSpread = (castPositions.max() ?? 0) - (castPositions.min() ?? 0)
        var spread: Double? = castSpread
        if includeAirPlay {
            if airPlay.isPlaying, let position = airPlay.currentTime, let sampled = airPlay.sampledAt,
               now >= sampled, now - sampled <= 3 {
                positions["airplay"] = position + now - sampled; samples["airplay"] = sampled
                if let range = airPlay.seekableRange { ranges.append(range) }
            }
            spread = airPlayAssessment?.difference.map { max(castSpread, abs($0 - airPlayTimingOffset)) }
        }
        let count = selectedDevices.count + (includeAirPlay ? 1 : 0)
        if alignmentWindow.observe(positions: positions, sampleTimes: samples, expectedCount: count, spread: spread, now: now) {
            finishPlaybackAlignment()
            return
        }
        guard alignmentWindow.canCorrect(at: now), positions.count == count else { return }
        if alignmentWindow.needsInitialSeek {
            guard ranges.count == count, let lower = ranges.map(\.lowerBound).max(), let upper = ranges.map(\.upperBound).min(),
                  upper - lower > 0.5 else { return }
            let anchor = max(lower + 0.25, upper - 1.5)
            guard quietFloor.map({ anchor >= $0 }) != false else { return }
            if includeAirPlay, !airPlay.seek(to: anchor) { return }
            sessions.resumeShared(at: anchor)
            alignmentWindow.corrected(at: now)
            mixedDrift.reset()
            logger.notice("Song-gap/startup common-anchor calibration at \(anchor); correction budget=1/2")
        } else if includeAirPlay {
            guard let assessment = airPlayAssessment,
                  let correction = mixedDrift.target(assessment: assessment, sampleTimes: samples, offset: airPlayTimingOffset, now: now) else { return }
            switch correction {
            case .airPlay(let target):
                guard quietFloor.map({ target >= $0 }) != false,
                      airPlay.seekableRanges.contains(where: { target >= $0.lowerBound + 0.1 && target <= $0.upperBound - 0.1 }), airPlay.seek(to: target) else { return }
            case .cast(let target):
                guard quietFloor.map({ target >= $0 }) != false,
                      receiverStatuses.values.allSatisfy({ $0.supportsSeek && $0.liveSeekableRange?.contains(target) == true }) else { return }
                sessions.resumeShared(at: target)
            }
            alignmentWindow.corrected(at: now)
            logger.notice("Bounded song-gap/startup follow-up calibration; correction budget=2/2")
        } else if sessions.canAlign {
            sessions.alignNow()
            alignmentWindow.corrected(at: now)
        }
    }

    private func finishPlaybackAlignment() {
        guard !completingAlignment else { return }
        guard musicSourceHeld else {
            logger.notice("Startup calibration ended; continuous source will not be corrected mid-playback")
            alignmentWindow.cancel(); return
        }
        guard resumeSourceAfterAlignment else { return }
        completingAlignment = true
        let revision = alignmentRevision, id = castingID
        logger.notice("Calibration gap complete; resuming source at 1× without replacing receiver sessions")
        musicMonitor?.resumeHeld(advance: pendingAdvance) { [weak self] resumed in
            Task { @MainActor [weak self] in
                guard let self, self.castingID == id, self.alignmentRevision == revision else { return }
                self.musicSourceHeld = false; self.completingAlignment = false; self.pendingAdvance = nil
                self.alignmentWindow.cancel(); self.quietFloor = nil
                self.appliedMusicPlayback = resumed ? true : nil
                self.message = resumed ? "Casting Apple Music. Local playback is muted." : "Music's queue is stopped. Choose a song to continue."
                if !resumed { self.synchronizeMusicPlayback() }
            }
        }
    }

    private func beginSongGap(advance: AppleMusicMonitor.Command?, sourceAlreadyStopped: Bool) {
        guard isCastingMacAudio, castSource == .appleMusic, needsCoordinatedStart, !musicSourceHeld else { return }
        musicSourceHeld = true; resumeSourceAfterAlignment = true; pendingAdvance = advance
        alignmentRevision = UUID(); alignmentWindow.cancel(); mixedDrift.reset()
        let revision = alignmentRevision, id = castingID
        message = "Finishing the song on both outputs…"
        let held: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.castingID == id, self.alignmentRevision == revision else { return }
                self.audioServer?.capturedTail { [weak self] tail in
                    Task { @MainActor [weak self] in
                        guard let self, self.castingID == id, self.alignmentRevision == revision else { return }
                        self.quietFloor = tail + 0.25
                        self.alignmentWindow.begin(at: ProcessInfo.processInfo.systemUptime, drainingThrough: tail)
                        self.logger.notice("Source held at song boundary; waiting for every buffered output past \(tail)")
                    }
                }
            }
        }
        if sourceAlreadyStopped { held() }
        else { musicMonitor?.holdForSkip(completion: held) }
    }

    func togglePlayback() {
        if isCastingMacAudio, musicSourceHeld {
            resumeSourceAfterAlignment.toggle()
            if resumeSourceAfterAlignment, alignmentWindow.phase == .finished { finishPlaybackAlignment() }
        }
        else if isCastingMacAudio { musicMonitor?.command(.playPause) }
        else if canControlPlayback { sessions.setPlaying(!isPlaying) }
    }

    func stopPlayback() {
        if isCastingMacAudio { stopMacAudio() }
        else if canStop { sessions.stopPlayback() }
    }

    func skipPrevious() {
        if isCastingMacAudio, musicSourceHeld, !completingAlignment {
            pendingAdvance = .previous; resumeSourceAfterAlignment = true
            if alignmentWindow.phase == .finished { finishPlaybackAlignment() }
        } else if isCastingMacAudio, needsCoordinatedStart, castSource == .appleMusic, !musicSourceHeld, musicTrack?.isPlaying == true {
            beginSongGap(advance: .previous, sourceAlreadyStopped: false)
        } else if isCastingMacAudio { musicMonitor?.command(.previous) }
        else if canSkipPrevious { sessions.skip(next: false) }
    }

    func skipNext() {
        if isCastingMacAudio, musicSourceHeld, !completingAlignment {
            pendingAdvance = .next; resumeSourceAfterAlignment = true
            if alignmentWindow.phase == .finished { finishPlaybackAlignment() }
        } else if isCastingMacAudio, needsCoordinatedStart, castSource == .appleMusic, !musicSourceHeld, musicTrack?.isPlaying == true {
            beginSongGap(advance: .next, sourceAlreadyStopped: false)
        } else if isCastingMacAudio { musicMonitor?.command(.next) }
        else if canSkipNext { sessions.skip(next: true) }
    }

    func setVolume(_ value: Double) {
        volume = value
        sessions.setVolume(value)
    }

    func setVolume(_ value: Double, for device: CastDevice) { sessions.setVolume(value, deviceID: device.id) }

    func retryMusicInfo() { musicMessage = ""; musicMonitor?.start(coordinated: needsCoordinatedStart) }

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
        mixedDrift.reset()
        alignmentWindow.cancel(); alignmentRevision = UUID(); quietFloor = nil
        musicSourceHeld = castSource == .appleMusic && needsCoordinatedStart
        resumeSourceAfterAlignment = musicSourceHeld
        pendingAdvance = nil; completingAlignment = false
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
                if source == .appleMusic {
                    let monitor = startMusicMonitor(id: id)
                    if needsCoordinatedStart {
                        resumeSourceAfterAlignment = try await monitor.holdForStartup()
                        guard castingID == id else { return }
                    }
                }
                try await tap.startCapture { [audioRelay] pcm in audioRelay.append(pcm) }
                guard castingID == id else { tap.stop(); return }
                audioCaptureStarted = true
                try openAudioStream()
                message = "Waiting for selected destinations. Local playback is muted."
            } catch {
                guard castingID == id else { return }
                stopMacAudio()
                message = error.localizedDescription
            }
        }
    }

    private func startMusicMonitor(id: UUID) -> AppleMusicMonitor {
        let monitor = AppleMusicMonitor()
        monitor.onTrack = { [weak self] track in
            Task { @MainActor [weak self] in
                guard let self, self.castingID == id else { return }
                let previous = self.musicTrack
                self.musicTrack = track
                if let track, self.musicSourceHeld, !self.completingAlignment,
                   let previous, track.id != previous.id, track.isPlaying {
                    self.alignmentRevision = UUID(); self.alignmentWindow.cancel()
                    self.musicSourceHeld = false; self.pendingAdvance = nil; self.quietFloor = nil
                    self.appliedMusicPlayback = true
                }
                if track?.atNaturalEnd == true { self.beginSongGap(advance: nil, sourceAlreadyStopped: true) }
                if let track, track.id != self.publishedTrackID || track.artwork != previous?.artwork ||
                    track.title != previous?.title || track.artist != previous?.artist || track.album != previous?.album {
                    self.publishMusicTrack(track)
                }
                self.confirmSharedPlaybackIfReady()
                self.synchronizeMusicPlayback()
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
        monitor.start(coordinated: needsCoordinatedStart)
        return monitor
    }

    func stopMacAudio(reason: String = "Stopped by user or app lifecycle") {
        guard isCastingMacAudio else { return }
        logger.notice("Shared stream stopping: \(reason, privacy: .public)")
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        castingID = nil
        alignmentRevision = UUID(); alignmentWindow.cancel(); quietFloor = nil
        playbackAttemptID = UUID()
        audioStreamID = UUID()
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
        musicMonitor?.stop(resumeHeld: resumeSourceAfterAlignment, advanceHeld: pendingAdvance)
        musicMonitor = nil
        musicTrack = nil
        musicSourceHeld = false; resumeSourceAfterAlignment = false; pendingAdvance = nil; completingAlignment = false
        publishedTrackID = nil
        appliedMusicPlayback = nil
        airPlay.stop()
        airPlayTimingMessage = ""
        musicMessage = ""
        audioQuality = ""
        liveURL = nil
        airPlayURL = nil
        castPlaybackConfirmed = false
        castReceiversConfirmed = false
        sessions.cancelMacAudio(); updateDestinations()
        message = "Stopping capture…"
    }

    private func synchronizeMusicPlayback() {
        guard isCastingMacAudio, castSource == .appleMusic, castPlaybackConfirmed, !musicSourceHeld,
              let track = musicTrack,
              appliedMusicPlayback != track.isPlaying else { return }
        if includeAirPlay, track.isPlaying, appliedMusicPlayback == false {
            airPlay.refreshRoute()
            guard airPlay.isAirPlayRouteSelected else {
                stopMacAudio(); message = "AirPlay disconnected while paused. Select the TV and start casting again."; return
            }
            // Both receivers keep their sessions through pause. The source
            // clock advances with silence, so resume inside today's live window.
            let anchor = sessions.liveAnchor.flatMap { target in
                airPlay.seekableRanges.contains(where: { $0.contains(target) }) ? target : nil
            }
            mixedDrift.reset()
            appliedMusicPlayback = true
            if airPlay.play(at: anchor) { sessions.resumeShared(at: anchor) }
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
            else { logger.notice("Music reported paused; pausing every output"); airPlay.pause() }
        }
        sessions.setPlaying(track.isPlaying)
        message = track.isPlaying ? "Casting Apple Music. Local playback is muted."
                                  : "Apple Music and all destinations are paused."
    }

    private func publishMusicTrack(_ track: MusicTrack) {
        publishedTrackID = track.id
        let jpeg = track.artwork.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) }
        let metadata = PlaybackMetadata(title: track.title, artist: track.artist, album: track.album, artwork: jpeg)
        audioServer?.updateNowPlaying(metadata)
        airPlay.updateMetadata(metadata)
        logger.notice("Now Playing updated inside the existing receiver session")
    }

    private func openAudioStream() throws {
        mixedDrift.reset()
        let streamID = UUID()
        audioStreamID = streamID
        castPlaybackConfirmed = false
        castReceiversConfirmed = false
        let playbackMetadata = PlaybackMetadata.macAudio
        let prefersIPv6 = selectedDevices.contains { $0.host.contains(":") || $0.host.hasSuffix(".local.") || $0.host.hasSuffix(".local") }
        let server = LiveAudioServer(sampleRate: castSampleRate, coordinatedStartup: needsCoordinatedStart, metadata: playbackMetadata, includeTVVideo: includeAirPlay, preferIPv6: prefersIPv6)
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Streaming home audio to network receivers")
        }
        audioServer = server
        audioRelay.route { [weak server] in server?.append($0) }
        server.onReady = { [weak self, weak server] url in
            Task { @MainActor [weak self] in
                guard let self, let server, self.isCastingMacAudio, self.audioStreamID == streamID else { return }
                var metadata = CastNowPlaying.macAudio
                if let track = self.musicTrack {
                    var artworkURL: URL?
                    if let jpeg = track.artwork.flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) }) {
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
                    let tvURL = metadata.streamURL(at: url.deletingLastPathComponent().appendingPathComponent("tv/live.m3u8"))
                    self.airPlayURL = tvURL
                    let currentMetadata = self.musicTrack.map { PlaybackMetadata(title: $0.title, artist: $0.artist, album: $0.album,
                        artwork: $0.artwork.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) }) } ?? playbackMetadata
                    self.airPlay.prepare(url: tvURL, metadata: currentMetadata)
                    self.message = "Choose your TV using the AirPlay button in Home Manager. Both outputs wait until it is ready."
                } else {
                    self.message = "Starting Mac audio…"
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
                self.stopMacAudio(reason: error)
                self.message = error
            }
        }
        try server.start()
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
            self.stopMacAudio(reason: "Startup timed out before every destination confirmed playback")
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
