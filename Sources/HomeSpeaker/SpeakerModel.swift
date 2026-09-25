import AppKit
import CoreAudio
import Foundation

struct CastDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let model: String
    let host: String
    let port: UInt16
}

@MainActor
final class SpeakerModel: NSObject, ObservableObject {
    @Published private(set) var devices: [CastDevice] = []
    @Published private(set) var selectedDevice: CastDevice?
    @Published private(set) var isConnected = false
    @Published private(set) var isCastingMacAudio = false
    @Published private(set) var isChangingTrack = false
    @Published private(set) var audioCaptureStarted = false
    @Published private(set) var isRestoringAudio = false
    @Published private(set) var volume = 0.5
    @Published private(set) var message = "Ready to scan."
    @Published private(set) var musicMessage = ""
    @Published private(set) var audioQuality = ""
    @Published private(set) var musicTrack: MusicTrack?
    @Published var castSource: CastAudioSource = .system
    @Published private var receiverStatus = CastStatus()

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
    var canControlPlayback: Bool { isCastingMacAudio ? musicTrack != nil && !isChangingTrack : isConnected && receiverStatus.mediaSessionID != nil }
    var canSkipNext: Bool { isCastingMacAudio ? musicTrack != nil && !isChangingTrack : isConnected && receiverStatus.supportsNext }
    var canSkipPrevious: Bool { isCastingMacAudio ? musicTrack != nil && !isChangingTrack : isConnected && receiverStatus.supportsPrevious }
    var canStop: Bool { isCastingMacAudio || canControlPlayback }

    private var browser: NetServiceBrowser?
    private var resolving: [String: NetService] = [:]
    private var client: CastClient?
    private var audioTap: SystemAudioTap?
    private var audioServer: LiveAudioServer?
    private var musicMonitor: AppleMusicMonitor?
    private var scanGeneration = 0
    private var connectionID = UUID()
    private var castingID: UUID?
    private var liveURL: URL?
    private var castPlaybackConfirmed = false
    private var publishedTrackID: String?
    private var appliedMusicPlayback: Bool?
    private var audioStreamID = UUID()
    private var playbackAttemptID = UUID()
    private var castSampleRate = 48_000
    private let audioRelay = PCMStreamRelay()

    func start() {
        scanAgain()
    }

    func stop() {
        stopMacAudio()
        connectionID = UUID()
        browser?.stop()
        browser = nil
        client?.disconnect()
        client = nil
        isConnected = false
    }

    func scanAgain() {
        scanGeneration += 1
        let generation = scanGeneration
        browser?.stop()
        devices.removeAll()
        resolving.removeAll()
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        browser.searchForServices(ofType: "_googlecast._tcp.", inDomain: "local.")
        if !isCastingMacAudio { message = "Searching for Cast speakers…" }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.scanGeneration == generation, self.devices.isEmpty else { return }
            self.message = "No Cast speakers found. Check Wi-Fi and Local Network access, then scan again."
        }
    }

    func connect(to device: CastDevice) {
        stopMacAudio()
        connectionID = UUID()
        let generation = connectionID
        client?.disconnect()
        isConnected = false
        selectedDevice = device
        receiverStatus = CastStatus()
        message = "Connecting to \(device.name)…"
        let client = CastClient(device: device)
        client.onStatus = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, self.connectionID == generation else { return }
                self.volume = status.volume
                let firstStatus = !self.isConnected
                self.isConnected = true
                self.receiverStatus = status
                if self.isCastingMacAudio {
                    if let liveURL = self.liveURL, status.contentID == liveURL.absoluteString, status.playerState == "PLAYING" {
                        self.castPlaybackConfirmed = true
                        self.isChangingTrack = false
                        self.message = "Casting \(self.castSource.rawValue) to \(device.name). Local playback is muted."
                    } else if let liveURL = self.liveURL, status.contentID == liveURL.absoluteString,
                              status.playerState == "BUFFERING" {
                        self.message = "Speaker is buffering live audio…"
                    } else if self.castPlaybackConfirmed,
                              status.receiverAppID != "CC1AD845" || status.contentID != self.liveURL?.absoluteString || status.playerState == "IDLE" {
                        self.stopMacAudio()
                        self.message = "Speaker playback changed. Casting stopped and Mac sound was restored."
                    }
                } else if firstStatus {
                    self.message = "Connected to \(device.name)."
                }
            }
        }
        client.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.connectionID == generation else { return }
                self.stopMacAudio()
                self.message = error
            }
        }
        client.onDisconnect = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connectionID == generation else { return }
                self.stopMacAudio()
                self.isConnected = false
                self.receiverStatus = CastStatus()
                self.message = "Speaker disconnected. Mac sound was restored. Select the speaker to reconnect."
            }
        }
        client.onProgress = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.connectionID == generation else { return }
                self.message = progress
            }
        }
        self.client = client
        client.connect()
    }

    func togglePlayback() {
        if isCastingMacAudio { musicMonitor?.command(.playPause) }
        else { client?.setPlaying(!isPlaying) }
    }

    func stopPlayback() {
        if isCastingMacAudio { stopMacAudio() }
        else { client?.stopPlayback() }
    }

    func skipPrevious() {
        if isCastingMacAudio { changeMusicTrack(.previous) }
        else { client?.skip(next: false) }
    }

    func skipNext() {
        if isCastingMacAudio { changeMusicTrack(.next) }
        else { client?.skip(next: true) }
    }

    func setVolume(_ value: Double) {
        volume = value
        client?.setVolume(value)
    }

    func retryMusicInfo() { musicMessage = ""; musicMonitor?.start() }

    func startMacAudio() {
        guard !isCastingMacAudio, !isRestoringAudio else { return }
        guard isConnected, client != nil else {
            message = "Connect to a speaker before sending Mac audio."
            return
        }
        let id = UUID()
        castingID = id
        isCastingMacAudio = true
        castPlaybackConfirmed = false
        musicTrack = nil
        musicMessage = ""
        let source = castSource
        let tap = SystemAudioTap()
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
                let monitor = AppleMusicMonitor()
                monitor.onTrack = { [weak self] track in
                    Task { @MainActor [weak self] in
                        guard let self, self.castingID == id else { return }
                        guard !self.isChangingTrack else {
                            if track?.id == self.publishedTrackID { self.musicTrack = track }
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
                message = "Waiting for the speaker. Local playback is muted."
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
        audioStreamID = UUID()
        isChangingTrack = false
        audioRelay.route(to: nil)
        isCastingMacAudio = false
        audioCaptureStarted = false
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
        musicMessage = ""
        audioQuality = ""
        liveURL = nil
        castPlaybackConfirmed = false
        client?.cancelMacAudio()
        message = "Stopping capture…"
    }

    private func synchronizeMusicPlayback() {
        guard isCastingMacAudio, castSource == .appleMusic, castPlaybackConfirmed,
              !isChangingTrack, let track = musicTrack,
              appliedMusicPlayback != track.isPlaying else { return }
        let wasPaused = appliedMusicPlayback == false
        appliedMusicPlayback = track.isPlaying
        if track.isPlaying, wasPaused {
            castPlaybackConfirmed = false
            client?.resumeMacAudio()
            watchPlaybackStartup()
        } else { client?.setPlaying(track.isPlaying) }
        message = track.isPlaying ? "Casting Apple Music. Local playback is muted."
                                  : "Apple Music and the speaker are paused."
    }

    private func changeMusicTrack(_ command: AppleMusicMonitor.Command?, observedTrack: MusicTrack? = nil) {
        guard isCastingMacAudio, !isChangingTrack, let monitor = musicMonitor else { return }
        let resumeMusic = command != nil || (observedTrack ?? musicTrack)?.isPlaying == true
        let rewind = command != nil || publishedTrackID != nil
        isChangingTrack = true
        castPlaybackConfirmed = false
        audioStreamID = UUID()
        let transition = audioStreamID
        liveURL = nil
        audioRelay.route(to: nil)
        audioServer?.stop()
        audioServer = nil
        client?.cancelMacAudio()
        message = "Changing song. Clearing the speaker's buffered audio…"
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
        publishedTrackID = track?.id
        appliedMusicPlayback = nil
        let server = LiveAudioServer(sampleRate: castSampleRate)
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
                self.client?.playMacAudio(at: url, metadata: metadata)
                self.message = resumeMusic ? "Preparing the speaker for the new song…" : "Starting Mac audio…"
            }
        }
        server.onReceiver = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isCastingMacAudio, self.audioStreamID == streamID else { return }
                self.message = "Speaker is buffering the new stream. Local playback is muted."
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
        if resumeMusic, let track { musicMonitor?.resumePreparedTrack(track.id) }
        watchPlaybackStartup()
    }

    private func watchPlaybackStartup() {
        let attempt = UUID()
        playbackAttemptID = attempt
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, self.isCastingMacAudio, self.playbackAttemptID == attempt, !self.castPlaybackConfirmed else { return }
            self.stopMacAudio()
            self.message = "Speaker did not start playback. Check Wi-Fi and try again."
        }
    }


}

extension SpeakerModel: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            let key = service.name + service.domain
            resolving[key] = service
            service.delegate = self
            service.resolve(withTimeout: 8)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        Task { @MainActor in
            let key = service.name + service.domain
            resolving.removeValue(forKey: key)
            devices.removeAll { $0.id == key }
            if selectedDevice?.id == key {
                stopMacAudio()
                client?.disconnect()
                client = nil
                isConnected = false
                selectedDevice = nil
                receiverStatus = CastStatus()
                message = "Speaker went offline."
            }
        }
    }

    nonisolated func netServiceDidResolveAddress(_ service: NetService) {
        Task { @MainActor in
            let key = service.name + service.domain
            guard let resolvedHost = service.hostName, service.port > 0, service.port <= 65535 else { return }
            let host = service.addresses?.compactMap { address -> String? in
                address.withUnsafeBytes { bytes -> String? in
                    guard let pointer = bytes.baseAddress?.assumingMemoryBound(to: sockaddr.self),
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
            resolving.removeValue(forKey: key)
            if !isCastingMacAudio && !isConnected { message = "Found \(devices.count) Cast device\(devices.count == 1 ? "" : "s")." }
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        Task { @MainActor in message = "Could not scan the local network. Check Local Network access in System Settings." }
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
