import Foundation
import Network
import Security
import OSLog

struct CastStatus {
    var volume = 0.5
    var title = ""
    var artist = ""
    var isPlaying = false
    var mediaSessionID: Int?
    var supportsNext = false
    var supportsPrevious = false
    var contentID: String?
    var playerState = "IDLE"
    var receiverAppID: String?
    var artworkURL: URL?
    var currentTime: Double?
    var playbackRate: Double?
    var positionSampledAt: TimeInterval?
    var supportsSeek = false
    var supportsPause = false
    var liveSeekableRange: ClosedRange<Double>?

    func estimatedPosition(at now: TimeInterval) -> Double? {
        guard let currentTime, let sampled = positionSampledAt, now >= sampled, now - sampled <= 3,
              currentTime.isFinite else { return nil }
        if playerState == "PAUSED" { return currentTime }
        guard playerState == "PLAYING", let playbackRate, playbackRate.isFinite, playbackRate > 0 else { return nil }
        let position = currentTime + (now - sampled) * playbackRate
        return position.isFinite ? position : nil
    }

    mutating func clearTiming() {
        currentTime = nil; playbackRate = nil; positionSampledAt = nil
        supportsSeek = false; supportsPause = false; liveSeekableRange = nil
    }

    mutating func updateTiming(_ media: [String: Any], at now: TimeInterval) {
        if let state = media["playerState"] as? String, state != playerState {
            currentTime = estimatedPosition(at: now)
            positionSampledAt = currentTime == nil ? nil : now
            playerState = state
        }
        if let time = media["currentTime"] as? Double, time.isFinite, time >= 0 {
            currentTime = time; positionSampledAt = now
        }
        if let rate = media["playbackRate"] as? Double, rate.isFinite, rate >= 0 {
            if rate != playbackRate, media["currentTime"] == nil {
                currentTime = estimatedPosition(at: now)
                positionSampledAt = currentTime == nil ? nil : now
            }
            playbackRate = rate
        }
        if let flags = media["supportedMediaCommands"] as? Int {
            supportsPause = flags & 1 != 0; supportsSeek = flags & 2 != 0
        }
        if media.keys.contains("liveSeekableRange") {
            liveSeekableRange = nil
            if let range = media["liveSeekableRange"] as? [String: Any], range["isLiveDone"] as? Bool != true,
               let start = range["start"] as? Double, let end = range["end"] as? Double,
               start.isFinite, end.isFinite, start >= 0, end > start { liveSeekableRange = start...end }
        }
    }

    mutating func updateMediaInfo(_ info: [String: Any]) {
        if let nextContentID = info["contentId"] as? String, nextContentID != contentID {
            contentID = nextContentID
            title = ""
            artist = ""
            artworkURL = nil
            clearTiming()
        }
        guard let metadata = info["metadata"] as? [String: Any] else { return }
        title = metadata["title"] as? String ?? ""
        artist = metadata["artist"] as? String ?? ""
        artworkURL = (metadata["images"] as? [[String: Any]])?.compactMap { image -> URL? in
            guard let value = image["url"] as? String, let url = URL(string: value),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            return url
        }.first
    }
}

/// Network-boundary interface shared by the receiver coordinator and Cast V2 client.
protocol CastControlling: AnyObject {
    var onStatus: ((CastStatus) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var onProgress: ((String) -> Void)? { get set }
    var onDisconnect: (() -> Void)? { get set }
    func connect()
    func disconnect()
    func setVolume(_ level: Double)
    func setPlaying(_ playing: Bool)
    func stopPlayback()
    func skip(next: Bool)
    func playMacAudio(at url: URL, metadata: CastNowPlaying, autoplay: Bool, currentTime: Double?)
    func cancelMacAudio()
    func requestMediaStatus()
    func seekLiveAudio(to time: Double)
}

/// The small subset of Cast V2 needed for receiver status and media controls.
/// This does not configure the speaker or access a Google account.
final class CastClient: CastControlling {
    var onStatus: ((CastStatus) -> Void)?
    var onError: ((String) -> Void)?
    var onProgress: ((String) -> Void)?
    var onDisconnect: (() -> Void)?

    private let logger = Logger(subsystem: "za.shudu.homespeaker", category: "CastPlayback")
    private let device: CastDevice
    private let connectionFactory: (NWEndpoint.Host, NWEndpoint.Port, NWParameters) -> NWConnection
    private let queue = DispatchQueue(label: "HomeSpeaker.CastClient")
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var incoming = Data()
    private var transportID: String?
    private var status = CastStatus()
    private var requestID = 1
    private var pendingLiveURL: URL?
    private var requestedLiveURL: URL?
    private var liveCancelled = false
    private var nowPlaying = CastNowPlaying.macAudio
    private var liveAutoplay = true
    private var liveStartTime: Double?
    private var recovery = CastConnectionRecovery()
    private var recovering = false
    private var recoveryGeneration = UUID()
    init(device: CastDevice,
         connectionFactory: @escaping (NWEndpoint.Host, NWEndpoint.Port, NWParameters) -> NWConnection = { NWConnection(host: $0, port: $1, using: $2) }) {
        self.device = device
        self.connectionFactory = connectionFactory
    }

    func connect() {
        queue.async { [self] in
            recovery.reset()
            recovering = false
            openConnection()
        }
    }

    private func openConnection() {
        let tls = NWProtocolTLS.Options()
        // Cast receivers present a local self-signed certificate.
        // Restrict the connection to the address discovered via Bonjour.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let connection = connectionFactory(NWEndpoint.Host(device.host), NWEndpoint.Port(rawValue: device.port)!, NWParameters(tls: tls))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            switch state {
            case .ready:
                self.onProgress?(self.recovering ? "Restoring speaker controls…" : "Secure Cast connection open; reading speaker status…")
                self.send(namespace: "urn:x-cast:com.google.cast.tp.connection", destination: "receiver-0", body: ["type": "CONNECT"])
                self.requestStatus()
                self.receive()
                self.startTimer()
            case .failed(let error):
                self.connectionFailed("Cast connection failed: \(error.localizedDescription)")
            case .waiting(let error):
                self.onProgress?("Waiting for Cast network: \(error.localizedDescription)")
            case .cancelled:
                self.connectionFailed("Cast control connection was interrupted.")
            case .preparing:
                self.onProgress?("Opening a secure Cast connection…")
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + (recovering ? 4 : 12)) { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection else { return }
            if case .ready = connection.state, !self.recovering { return }
            self.connectionFailed("Cast connection timed out. Check the speaker's local network access.")
        }
    }

    private func connectionFailed(_ message: String) {
        let ownsStream = !liveCancelled && pendingLiveURL == nil && requestedLiveURL != nil
        guard let delay = recovery.retryDelay(at: ProcessInfo.processInfo.systemUptime, ownsActiveStream: ownsStream) else {
            onError?(message)
            disconnectOnQueue()
            return
        }
        logger.warning("Cast control connection interrupted; preserving live media and retrying in \(delay) s")
        timer?.cancel(); timer = nil
        let old = connection
        connection = nil
        old?.cancel()
        incoming.removeAll()
        // Keep media identity/timing for reconciliation, but CONNECT again to the
        // current app transport on the replacement socket. Do not LAUNCH/LOAD.
        transportID = nil
        recovering = true
        let id = UUID()
        recoveryGeneration = id
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.recoveryGeneration == id, self.recovering, !self.liveCancelled else { return }
            self.openConnection()
        }
    }

    func disconnect() {
        queue.async { [self] in disconnectOnQueue() }
    }

    func setVolume(_ level: Double) {
        queue.async { [self] in
            send(namespace: "urn:x-cast:com.google.cast.receiver", destination: "receiver-0", body: [
                "type": "SET_VOLUME",
                "volume": ["level": max(0, min(1, level))],
                "requestId": nextRequestID()
            ])
        }
    }

    func setPlaying(_ playing: Bool) {
        queue.async { [self] in
            logger.notice("Sending immediate receiver playback command: playing=\(playing)")
            guard let transportID, let mediaSessionID = status.mediaSessionID else { return }
            send(namespace: "urn:x-cast:com.google.cast.media", destination: transportID, body: [
                "type": playing ? "PLAY" : "PAUSE",
                "mediaSessionId": mediaSessionID,
                "requestId": nextRequestID()
            ])
        }
    }

    func stopPlayback() {
        queue.async { [self] in
            guard let transportID, let mediaSessionID = status.mediaSessionID else { return }
            send(namespace: "urn:x-cast:com.google.cast.media", destination: transportID, body: [
                "type": "STOP",
                "mediaSessionId": mediaSessionID,
                "requestId": nextRequestID()
            ])
        }
    }

    func skip(next: Bool) {
        queue.async { [self] in
            guard let transportID, let mediaSessionID = status.mediaSessionID else { return }
            send(namespace: "urn:x-cast:com.google.cast.media", destination: transportID, body: [
                "type": "QUEUE_UPDATE",
                "jump": next ? 1 : -1,
                "mediaSessionId": mediaSessionID,
                "requestId": nextRequestID()
            ])
        }
    }

    func playMacAudio(at url: URL, metadata: CastNowPlaying = .macAudio, autoplay: Bool = true, currentTime: Double? = nil) {
        queue.async { [self] in
            let url = metadata.streamURL(at: url)
            nowPlaying = metadata
            liveAutoplay = autoplay
            liveStartTime = currentTime.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            pendingLiveURL = url
            requestedLiveURL = url
            liveCancelled = false
            onProgress?("Opening the speaker's Cast player…")
            send(namespace: "urn:x-cast:com.google.cast.receiver", destination: "receiver-0", body: [
                "type": "LAUNCH", "appId": "CC1AD845", "requestId": nextRequestID()
            ])
            queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.pendingLiveURL == url else { return }
                self.pendingLiveURL = nil
                self.onError?("The speaker did not open its Cast player.")
            }
        }
    }

    func requestMediaStatus() {
        queue.async { [self] in
            guard let transportID else { return }
            send(namespace: "urn:x-cast:com.google.cast.media", destination: transportID,
                 body: ["type": "GET_STATUS", "requestId": nextRequestID()])
        }
    }

    func seekLiveAudio(to time: Double) {
        queue.async { [self] in
            guard !liveCancelled, let requestedLiveURL, status.contentID == requestedLiveURL.absoluteString,
                  status.supportsSeek, time.isFinite, let range = status.liveSeekableRange, range.contains(time),
                  let transportID, let session = status.mediaSessionID else { return }
            send(namespace: "urn:x-cast:com.google.cast.media", destination: transportID,
                 body: ["type": "SEEK", "currentTime": time, "resumeState": "PLAYBACK_START",
                        "mediaSessionId": session, "requestId": nextRequestID()])
        }
    }

    func cancelMacAudio() {
        queue.async { [self] in
            pendingLiveURL = nil
            liveCancelled = true
            nowPlaying = .macAudio
            stopCancelledLiveMedia()
        }
    }

    private func stopCancelledLiveMedia() {
        guard liveCancelled, let url = requestedLiveURL,
              status.contentID == url.absoluteString,
              let transportID, let session = status.mediaSessionID else { return }
        requestedLiveURL = nil
        send(namespace: "urn:x-cast:com.google.cast.media", destination: transportID,
             body: ["type": "STOP", "mediaSessionId": session, "requestId": nextRequestID()])
    }

    private func disconnectOnQueue() {
        let wasConnected = connection != nil || recovering
        recoveryGeneration = UUID()
        recovering = false
        recovery.reset()
        timer?.cancel()
        timer = nil
        connection?.cancel()
        connection = nil
        transportID = nil
        pendingLiveURL = nil
        requestedLiveURL = nil
        incoming.removeAll()
        if wasConnected { onDisconnect?() }
    }

    private func startTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.send(namespace: "urn:x-cast:com.google.cast.tp.heartbeat", destination: "receiver-0", body: ["type": "PING"])
            self.requestStatus()
        }
        self.timer = timer
        timer.resume()
    }

    private func requestStatus() {
        send(namespace: "urn:x-cast:com.google.cast.receiver", destination: "receiver-0", body: [
            "type": "GET_STATUS", "requestId": nextRequestID()
        ])
        if let transportID {
            send(namespace: "urn:x-cast:com.google.cast.media", destination: transportID, body: [
                "type": "GET_STATUS", "requestId": nextRequestID()
            ])
        }
    }

    private func nextRequestID() -> Int {
        defer { requestID += 1 }
        return requestID
    }

    private func send(namespace: String, destination: String, body: [String: Any]) {
        guard let connection, let payload = try? JSONSerialization.data(withJSONObject: body),
              let json = String(data: payload, encoding: .utf8) else { return }
        let message = CastWire.message(namespace: namespace, destination: destination, json: json)
        connection.send(content: message, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, self.connection === connection else { return }
            if let error { self.connectionFailed("Cast send failed: \(error.localizedDescription)") }
        })
    }

    private func receive() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, self.connection === connection else { return }
            if let data { self.incoming.append(data) }
            self.consumeMessages()
            guard self.connection === connection else { return }
            if let error {
                self.connectionFailed("Cast connection closed: \(error.localizedDescription)")
            } else if isComplete {
                self.connectionFailed("Cast connection closed by speaker.")
            } else {
                self.receive()
            }
        }
    }

    private func consumeMessages() {
        while incoming.count >= 4 {
            let length = incoming.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= 1_000_000 else {
                onError?("Invalid Cast message received.")
                disconnectOnQueue()
                return
            }
            guard incoming.count >= length + 4 else { return }
            let body = Data(incoming[4..<(length + 4)])
            incoming.removeSubrange(0..<(length + 4))
            guard let packet = CastWire.decode(body),
                  let data = packet.json.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            handle(namespace: packet.namespace, json: json)
        }
    }

    private func handle(namespace: String, json: [String: Any]) {
        let type = json["type"] as? String ?? ""
        if ["LAUNCH_ERROR", "LOAD_FAILED", "INVALID_REQUEST"].contains(type) {
            onError?("Speaker rejected Cast request: \(type).")
            pendingLiveURL = nil
            return
        }
        if namespace == "urn:x-cast:com.google.cast.tp.heartbeat", type == "PING" {
            send(namespace: namespace, destination: "receiver-0", body: ["type": "PONG"])
        } else if type == "RECEIVER_STATUS", let receiver = json["status"] as? [String: Any] {
            if let volume = receiver["volume"] as? [String: Any], let level = volume["level"] as? Double {
                status.volume = level
            }
            let app = (receiver["applications"] as? [[String: Any]])?.first
            status.receiverAppID = app?["appId"] as? String
            let nextTransport = app?["transportId"] as? String
            if nextTransport != transportID {
                transportID = nextTransport
                if !recovering {
                    status.title = ""
                    status.artist = ""
                    status.artworkURL = nil
                    status.isPlaying = false
                    status.mediaSessionID = nil
                    status.contentID = nil
                    status.playerState = "IDLE"
                    status.supportsNext = false
                    status.supportsPrevious = false
                    status.clearTiming()
                }
                if let nextTransport {
                    send(namespace: "urn:x-cast:com.google.cast.tp.connection", destination: nextTransport, body: ["type": "CONNECT"])
                    send(namespace: "urn:x-cast:com.google.cast.media", destination: nextTransport, body: [
                        "type": "GET_STATUS", "requestId": nextRequestID()
                    ])
                }
            }
            if let url = pendingLiveURL, let transportID,
               app?["appId"] as? String == "CC1AD845" {
                pendingLiveURL = nil
                var load: [String: Any] = ["type": "LOAD", "requestId": nextRequestID(), "autoplay": liveAutoplay,
                                          "playbackRate": 1.0, "media": nowPlaying.media(at: url)]
                if let liveStartTime { load["currentTime"] = liveStartTime }
                send(namespace: "urn:x-cast:com.google.cast.media", destination: transportID, body: load)
                onProgress?("Sending Mac audio to the speaker…")
            }
            if recovering, status.receiverAppID != "CC1AD845" || transportID == nil {
                onError?("Speaker changed playback while restoring its control connection.")
                disconnectOnQueue()
                return
            }
            onStatus?(status)
        } else if type == "MEDIA_STATUS" {
            let media = (json["status"] as? [[String: Any]])?.first
            if let reason = media?["idleReason"] as? String, reason == "ERROR" {
                onError?("Speaker could not play the Mac audio stream.")
            }
            if media == nil {
                status.mediaSessionID = nil
                status.contentID = nil
                status.title = ""
                status.artist = ""
                status.artworkURL = nil
                status.playerState = "IDLE"
                status.supportsNext = false
                status.supportsPrevious = false
                status.clearTiming()
            } else {
                let session = media?["mediaSessionId"] as? Int
                if let session, session != status.mediaSessionID {
                    status.contentID = nil
                    status.title = ""
                    status.artist = ""
                    status.artworkURL = nil
                    status.supportsNext = false
                    status.supportsPrevious = false
                    status.clearTiming()
                }
                if let session { status.mediaSessionID = session }
                if let state = media?["playerState"] as? String {
                    if status.playerState != state {
                        logger.notice("Receiver state changed: \(state, privacy: .public)")
                    }
                }
                // Cast may omit unchanged media and command fields in status updates.
                if let info = media?["media"] as? [String: Any] {
                    status.updateMediaInfo(info)
                }
                if let commands = media?["supportedMediaCommands"] as? Int {
                    status.supportsNext = commands & 64 != 0
                    status.supportsPrevious = commands & 128 != 0
                }
                if let media {
                    let previousRate = status.playbackRate
                    status.updateTiming(media, at: ProcessInfo.processInfo.systemUptime)
                    if status.playbackRate != previousRate {
                        logger.notice("Receiver media clock rate: \(self.status.playbackRate ?? -1), player=\(self.status.playerState, privacy: .public)")
                    }
                }
            }
            if recovering, let requestedLiveURL, status.contentID == requestedLiveURL.absoluteString,
               status.mediaSessionID != nil {
                recovering = false
                logger.notice("Cast controls restored to the existing media session without reloading audio")
            }
            status.isPlaying = status.playerState == "PLAYING"
            stopCancelledLiveMedia()
            onStatus?(status)
        }
    }
}

enum CastWire {
    static func message(namespace: String, destination: String, json: String) -> Data {
        var body = Data()
        appendVarintField(1, value: 0, to: &body) // CASTV2_1_0
        appendStringField(2, value: "sender-0", to: &body)
        appendStringField(3, value: destination, to: &body)
        appendStringField(4, value: namespace, to: &body)
        appendVarintField(5, value: 0, to: &body) // STRING
        appendStringField(6, value: json, to: &body)
        var framed = Data([
            UInt8((body.count >> 24) & 0xff), UInt8((body.count >> 16) & 0xff),
            UInt8((body.count >> 8) & 0xff), UInt8(body.count & 0xff)
        ])
        framed.append(body)
        return framed
    }

    static func decode(_ data: Data) -> (namespace: String, json: String)? {
        let bytes = Array(data)
        var position = 0
        var namespace: String?
        var json: String?
        while position < bytes.count {
            guard let key = readVarint(bytes, position: &position) else { return nil }
            let field = Int(key >> 3)
            let wireType = Int(key & 7)
            if wireType == 0 {
                guard readVarint(bytes, position: &position) != nil else { return nil }
            } else if wireType == 2 {
                guard let length = readVarint(bytes, position: &position),
                      length <= UInt64(bytes.count - position) else { return nil }
                let end = position + Int(length)
                if field == 4 { namespace = String(bytes: bytes[position..<end], encoding: .utf8) }
                if field == 6 { json = String(bytes: bytes[position..<end], encoding: .utf8) }
                position = end
            } else {
                return nil
            }
        }
        guard let namespace, let json else { return nil }
        return (namespace, json)
    }

    private static func appendVarintField(_ field: UInt64, value: UInt64, to data: inout Data) {
        appendVarint(field << 3, to: &data)
        appendVarint(value, to: &data)
    }

    private static func appendStringField(_ field: UInt64, value: String, to data: inout Data) {
        let utf8 = Array(value.utf8)
        appendVarint((field << 3) | 2, to: &data)
        appendVarint(UInt64(utf8.count), to: &data)
        data.append(contentsOf: utf8)
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    private static func readVarint(_ bytes: [UInt8], position: inout Int) -> UInt64? {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard position < bytes.count else { return nil }
            let byte = bytes[position]
            position += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
        }
        return nil
    }
}
