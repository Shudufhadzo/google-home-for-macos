import Foundation

/// Owns independent Cast connections while sharing one encoded audio timeline.
/// A Google Home group is one virtual receiver: its members synchronise themselves.
@MainActor
final class CastSessionCoordinator {
    var onUpdate: (() -> Void)?
    var onPrepared: (() -> Void)?
    var onPlaybackConfirmed: (() -> Void)?
    var onFailure: ((String) -> Void)?

    private struct Connection {
        let generation: UUID
        let client: any CastControlling
    }
    private let factory: (CastDevice) -> any CastControlling
    private let clock: () -> TimeInterval
    private var connections: [String: Connection] = [:]
    private var polling: Task<Void, Never>?
    private var prepared: Set<String> = []
    private var playing: Set<String> = []
    private var started: Set<String> = []
    private var seenLive: Set<String> = []
    private var waitsForCompanion = false
    private var companionReady = false
    private var playIssued = false
    private var confirmed = false
    private var driftSamples = 0
    private var lastSamples: [String: TimeInterval] = [:]
    private var lastCorrection = -Double.infinity
    private(set) var selectedDevices: [CastDevice] = []
    private(set) var statuses: [String: CastStatus] = [:]
    private(set) var connected: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var activeContentID: String?
    private(set) var message = "Select speakers, a Cast TV, or a Google Home group."
    private(set) var syncMessage = ""
    private(set) var canAlign = false

    var allConnected: Bool { !selectedDevices.isEmpty && selectedDevices.allSatisfy { connected.contains($0.id) } }
    var isGroup: Bool { selectedDevices.count == 1 && selectedDevices[0].isGroup }
    var primaryStatus: CastStatus { selectedDevices.first.flatMap { statuses[$0.id] } ?? CastStatus() }
    var destinationNames: String { selectedDevices.map(\.name).joined(separator: ", ") }

    init(clientFactory: @escaping (CastDevice) -> any CastControlling = { CastClient(device: $0) },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        factory = clientFactory; self.clock = clock
    }

    func select(_ device: CastDevice) {
        guard activeContentID == nil else { return }
        if connections[device.id] != nil { return }
        // Group membership is not advertised in Bonjour. Selecting both a group and
        // one of its members can make two sessions compete for the same receiver.
        if device.isGroup || selectedDevices.contains(where: \.isGroup) { disconnectAll() }
        guard selectedDevices.count < 8 else {
            message = "Select up to 8 individual receivers, or one Google Home group."; onUpdate?(); return
        }
        selectedDevices.append(device)
        let client = factory(device), generation = UUID()
        connections[device.id] = Connection(generation: generation, client: client)
        client.onStatus = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, self.connections[device.id]?.generation == generation else { return }
                self.receive(status, from: device)
            }
        }
        client.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.connections[device.id]?.generation == generation else { return }
                self.failed(device, message: error)
            }
        }
        client.onDisconnect = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.connections[device.id]?.generation == generation else { return }
                self.failed(device, message: "Disconnected. Remove and select this destination to reconnect.")
            }
        }
        client.onProgress = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.connections[device.id]?.generation == generation, self.activeContentID != nil else { return }
                self.message = "\(device.name): \(progress)"; self.onUpdate?()
            }
        }
        message = "Connecting to \(device.name)…"; onUpdate?(); client.connect()
    }

    func toggle(_ device: CastDevice) {
        guard activeContentID == nil else { return }
        if connections[device.id] == nil { select(device) } else { remove(device.id) }
    }

    func remove(_ id: String) {
        let name = selectedDevices.first { $0.id == id }?.name ?? "Receiver"
        if activeContentID != nil { cancelMacAudio(); onFailure?("\(name) went offline. Casting stopped and Mac sound was restored.") }
        let connection = connections.removeValue(forKey: id)
        selectedDevices.removeAll { $0.id == id }; statuses.removeValue(forKey: id)
        connected.remove(id); errors.removeValue(forKey: id)
        connection?.client.disconnect()
        message = selectedDevices.isEmpty ? "Select speakers, a Cast TV, or a Google Home group." : "Selected: \(destinationNames)."
        onUpdate?()
    }

    func disconnectAll() {
        cancelMacAudio()
        let old = connections.values.map(\.client)
        connections.removeAll(); selectedDevices.removeAll(); statuses.removeAll(); connected.removeAll(); errors.removeAll()
        for client in old { client.disconnect() }
        onUpdate?()
    }

    @discardableResult
    func playMacAudio(at url: URL, metadata: CastNowPlaying, waitForCompanion: Bool = false) -> Bool {
        guard allConnected else { message = "Wait for every selected destination to connect."; onUpdate?(); return false }
        cancelMacAudio()
        activeContentID = metadata.streamURL(at: url).absoluteString
        waitsForCompanion = waitForCompanion
        let multiple = selectedDevices.count > 1
        let coordinated = multiple || waitForCompanion
        syncMessage = isGroup ? "Google Home group handles synchronisation. Adjust group delay in Google Home if needed."
                             : multiple ? "Preparing all destinations at normal speed…" : ""
        if waitForCompanion { syncMessage = "Waiting for Cast and AirPlay to prepare the shared stream…" }
        message = "Preparing \(destinationNames)…"
        for device in selectedDevices {
            connections[device.id]?.client.playMacAudio(at: url, metadata: metadata, autoplay: !coordinated, currentTime: coordinated ? 0 : nil)
        }
        startPolling(); onUpdate?(); return true
    }

    /// Readiness belongs to a specific stream; delayed callbacks from a stopped
    /// AirPlay player must not release a newer Cast session.
    func markCompanionReady(contentID: String) {
        guard waitsForCompanion, !playIssued, activeContentID == contentID else { return }
        companionReady = true
        startWhenPrepared()
        onUpdate?()
    }

    func cancelMacAudio() {
        polling?.cancel(); polling = nil
        let hadStream = activeContentID != nil
        activeContentID = nil; prepared.removeAll(); playing.removeAll(); started.removeAll(); seenLive.removeAll()
        waitsForCompanion = false; companionReady = false
        playIssued = false; confirmed = false; driftSamples = 0; lastSamples.removeAll()
        lastCorrection = -Double.infinity; canAlign = false; syncMessage = ""
        if hadStream { for connection in connections.values { connection.client.cancelMacAudio() } }
    }

    func setPlaying(_ value: Bool) {
        guard allConnected else { return }
        guard !value || !waitsForCompanion || playIssued else { return }
        driftSamples = 0; lastSamples.removeAll()
        if value, let contentID = activeContentID, selectedDevices.count > 1,
           let anchor = CastSyncPlanner.commonLiveAnchor(statuses: liveStatuses, contentID: contentID, at: clock()) {
            for connection in connections.values { connection.client.seekLiveAudio(to: anchor) }
            lastCorrection = clock()
        } else { for connection in connections.values { connection.client.setPlaying(value) } }
    }
    func stopPlayback() { for connection in connections.values { connection.client.stopPlayback() } }
    func skip(next: Bool) { for connection in connections.values { connection.client.skip(next: next) } }
    func setVolume(_ value: Double, deviceID: String? = nil) {
        guard value.isFinite else { return }
        let level = max(0, min(1, value))
        if let deviceID { connections[deviceID]?.client.setVolume(level) }
        else { for connection in connections.values { connection.client.setVolume(level) } }
    }
    func alignNow() { updateSync(force: true); onUpdate?() }

    private var liveStatuses: [String: CastStatus] {
        Dictionary(uniqueKeysWithValues: selectedDevices.compactMap { device in statuses[device.id].map { (device.id, $0) } })
    }

    private func startWhenPrepared() {
        guard let contentID = activeContentID, !playIssued,
              selectedDevices.count > 1 || waitsForCompanion,
              prepared.count == selectedDevices.count,
              !waitsForCompanion || companionReady else { return }
        playIssued = true
        if waitsForCompanion { playing.removeAll() }
        onPrepared?()
        // Preparing the companion can fail synchronously and cancel the stream.
        guard activeContentID == contentID, playIssued else { return }
        if waitsForCompanion {
            // AirPlay was prepared at the beginning of this same stream. Seeking
            // Cast receivers to the live edge here would immediately separate them.
            for connection in connections.values { connection.client.setPlaying(true) }
            syncMessage = "Cast and AirPlay share the stream. Device buffering can add audible delay."
            message = "Starting \(destinationNames) and AirPlay together…"
        } else {
            setPlaying(true)
            message = "Starting all \(selectedDevices.count) destinations together…"
        }
    }

    private func receive(_ status: CastStatus, from device: CastDevice) {
        statuses[device.id] = status; connected.insert(device.id); errors.removeValue(forKey: device.id)
        guard let contentID = activeContentID else {
            message = allConnected ? "Connected to \(destinationNames)." : "Connecting selected destinations…"; onUpdate?(); return
        }
        if status.contentID == contentID, status.mediaSessionID != nil {
            let playbackWasIssued = playIssued
            if status.playerState == "PAUSED" || status.playerState == "PLAYING" { seenLive.insert(device.id) }
            // The media clock can be stopped (rate 0) in any player state,
            // including the transition from Buffering to Playing. That is not
            // slow/fast playback and must be allowed to finish priming.
            if let rate = status.playbackRate, status.playerState == "PLAYING", rate > 0, abs(rate - 1) > 0.001 {
                failed(device, message: "Receiver reported \(String(format: "%.3g", rate))× playback instead of 1×."); return
            }
            if status.playerState == "PAUSED" || status.playerState == "PLAYING" { prepared.insert(device.id) }
            else { prepared.remove(device.id) }
            if selectedDevices.count > 1 || waitsForCompanion, !playIssued {
                startWhenPrepared()
                guard activeContentID == contentID else { return }
                if !playIssued, status.playerState == "PLAYING" {
                    guard status.supportsPause else {
                        let reason = waitsForCompanion
                            ? "Receiver cannot pause while AirPlay prepares. Reconnect this destination and try again."
                            : "Receiver cannot pause for a coordinated start. Use a Google Home group."
                        failed(device, message: reason); return
                    }
                    connections[device.id]?.client.setPlaying(false)
                }
            }
            // Early autoplay (including the report that releases the barrier)
            // predates our PLAY command and cannot confirm mixed playback.
            if status.playerState == "PLAYING", !waitsForCompanion || playbackWasIssued {
                playing.insert(device.id); started.insert(device.id)
            } else { playing.remove(device.id) }
            if playing.count == selectedDevices.count, !confirmed {
                confirmed = true; onPlaybackConfirmed?()
                message = "Casting to \(destinationNames). Local playback is muted."
            }
            if confirmed { updateSync(force: false) }
        } else if seenLive.contains(device.id),
                  status.receiverAppID != "CC1AD845" || status.contentID != contentID {
            failed(device, message: "Playback changed on this destination."); return
        }
        if status.contentID == contentID, status.playerState == "IDLE", started.contains(device.id) {
            failed(device, message: "Receiver stopped the live stream."); return
        }
        onUpdate?()
    }

    private func failed(_ device: CastDevice, message error: String) {
        let hadStream = activeContentID != nil
        connected.remove(device.id); statuses.removeValue(forKey: device.id); errors[device.id] = error
        cancelMacAudio()
        if let failed = connections[device.id] {
            // A failed receiver needs a fresh connection. Retain the selection,
            // but reject already queued callbacks from its retired connection.
            connections[device.id] = Connection(generation: UUID(), client: failed.client)
            failed.client.disconnect()
        }
        message = "\(device.name): \(error)"
        onFailure?(hadStream ? message + " Casting stopped and Mac sound was restored." : message)
        onUpdate?()
    }

    private func startPolling() {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, self.activeContentID != nil else { return }
                for connection in self.connections.values { connection.client.requestMediaStatus() }
                self.updateSync(force: false); self.onUpdate?()
            }
        }
    }

    private func updateSync(force: Bool) {
        guard let contentID = activeContentID, selectedDevices.count > 1 else { return }
        guard !waitsForCompanion || playIssued else { return }
        let assessment = CastSyncPlanner.assess(statuses: liveStatuses, contentID: contentID, at: clock())
        canAlign = !assessment.corrections.isEmpty && clock() - lastCorrection >= 8
        guard let spread = assessment.spread else {
            syncMessage = assessment.note; driftSamples = 0; return
        }
        syncMessage = "Estimated receiver spread: \(String(format: "%.0f", spread * 1000)) ms. \(assessment.note)"
        let samples = liveStatuses.compactMapValues(\.positionSampledAt)
        let freshRound = samples.count == selectedDevices.count && samples.allSatisfy { $0.value > (lastSamples[$0.key] ?? -Double.infinity) }
        if freshRound {
            lastSamples = samples
            driftSamples = spread > CastSyncPlanner.tolerance ? driftSamples + 1 : 0
        }
        guard (force || driftSamples >= 3), canAlign else { return }
        for (id, position) in assessment.corrections { connections[id]?.client.seekLiveAudio(to: position) }
        lastCorrection = clock(); driftSamples = 0; canAlign = false
        syncMessage = "Aligning receiver timelines at 1× speed. TV audio processing can add audible delay."
    }
}
