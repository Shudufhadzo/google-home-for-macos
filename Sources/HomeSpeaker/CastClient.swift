import Foundation
import Network
import Security

struct CastStatus {
    var volume = 0.5
    var title = ""
    var artist = ""
    var isPlaying = false
    var mediaSessionID: Int?
    var supportsNext = false
    var supportsPrevious = false
}

/// The small subset of Cast V2 needed for receiver status and media controls.
/// This does not configure the speaker or access a Google account.
final class CastClient {
    var onStatus: ((CastStatus) -> Void)?
    var onError: ((String) -> Void)?
    var onProgress: ((String) -> Void)?

    private let device: CastDevice
    private let queue = DispatchQueue(label: "HomeSpeaker.CastClient")
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var incoming = Data()
    private var transportID: String?
    private var status = CastStatus()
    private var requestID = 1
    private var pendingLiveURL: URL?

    init(device: CastDevice) {
        self.device = device
    }

    func connect() {
        queue.async { [self] in
            let tls = NWProtocolTLS.Options()
            // Cast receivers present a local self-signed certificate.
            // Restrict the connection to the address discovered via Bonjour.
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
                complete(true)
            }, queue)
            let parameters = NWParameters(tls: tls)
            let connection = NWConnection(
                host: NWEndpoint.Host(device.host),
                port: NWEndpoint.Port(rawValue: device.port)!,
                using: parameters
            )
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.onProgress?("Secure Cast connection open; reading speaker status…")
                    self.send(namespace: "urn:x-cast:com.google.cast.tp.connection", destination: "receiver-0", body: ["type": "CONNECT"])
                    self.requestStatus()
                    self.receive()
                    self.startTimer()
                case .failed(let error):
                    self.onError?("Cast connection failed: \(error.localizedDescription)")
                    self.disconnectOnQueue()
                case .waiting(let error):
                    self.onProgress?("Waiting for Cast network: \(error.localizedDescription)")
                case .preparing:
                    self.onProgress?("Opening a secure Cast connection…")
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 12) { [weak self, weak connection] in
                guard let self, let connection, self.connection === connection else { return }
                if case .ready = connection.state { return }
                self.onError?("Cast connection timed out. Check the speaker's local network access.")
                self.disconnectOnQueue()
            }
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

    func playMacAudio(at url: URL) {
        queue.async { [self] in
            pendingLiveURL = url
            onProgress?("Opening the speaker's Cast player…")
            send(namespace: "urn:x-cast:com.google.cast.receiver", destination: "receiver-0", body: [
                "type": "LAUNCH", "appId": "CC1AD845", "requestId": nextRequestID()
            ])
            queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.pendingLiveURL != nil else { return }
                self.pendingLiveURL = nil
                self.onError?("The speaker did not open its Cast player.")
            }
        }
    }

    private func disconnectOnQueue() {
        timer?.cancel()
        timer = nil
        connection?.cancel()
        connection = nil
        transportID = nil
        pendingLiveURL = nil
        incoming.removeAll()
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
        connection.send(content: message, completion: .contentProcessed { [weak self] error in
            if let error { self?.onError?("Cast send failed: \(error.localizedDescription)") }
        })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.incoming.append(data) }
            self.consumeMessages()
            if let error {
                self.onError?("Cast connection closed: \(error.localizedDescription)")
                self.disconnectOnQueue()
            } else if isComplete {
                self.onError?("Cast connection closed by speaker.")
                self.disconnectOnQueue()
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
            let nextTransport = app?["transportId"] as? String
            if nextTransport != transportID {
                transportID = nextTransport
                status.title = ""
                status.artist = ""
                status.isPlaying = false
                status.mediaSessionID = nil
                status.supportsNext = false
                status.supportsPrevious = false
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
                send(namespace: "urn:x-cast:com.google.cast.media", destination: transportID, body: [
                    "type": "LOAD", "requestId": nextRequestID(), "autoplay": true,
                    "media": ["contentId": url.absoluteString, "contentType": "audio/wav",
                              "streamType": "LIVE", "metadata": ["metadataType": 0, "title": "Mac audio"]]
                ])
                onProgress?("Sending Mac audio to the speaker…")
            }
            onStatus?(status)
        } else if type == "MEDIA_STATUS" {
            let media = (json["status"] as? [[String: Any]])?.first
            if let reason = media?["idleReason"] as? String, reason == "ERROR" {
                onError?("Speaker could not play the Mac audio stream.")
            }
            status.mediaSessionID = media?["mediaSessionId"] as? Int
            status.isPlaying = (media?["playerState"] as? String) == "PLAYING"
            let metadata = (media?["media"] as? [String: Any])?["metadata"] as? [String: Any]
            status.title = metadata?["title"] as? String ?? ""
            status.artist = metadata?["artist"] as? String ?? ""
            let commands = media?["supportedMediaCommands"] as? Int ?? 0
            status.supportsNext = commands & 64 != 0
            status.supportsPrevious = commands & 128 != 0
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
