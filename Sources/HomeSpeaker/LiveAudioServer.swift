import Foundation
import Network

/// A temporary local PCM stream with bounded, ordered delivery and explicit failure.
final class LiveAudioServer {
    var onReady: ((URL) -> Void)?
    var onError: ((String) -> Void)?
    var onReceiver: (() -> Void)?

    private let queue = DispatchQueue(label: "HomeSpeaker.LiveAudioServer")
    private var listener: NWListener?
    private var receiver: NWConnection?
    private var requests: [ObjectIdentifier: NWConnection] = [:]
    private var timer: DispatchSourceTimer?
    private var sending = false
    private var stopped = false
    private var artwork: Data?
    private let token = UUID().uuidString
    private let sampleRate: Int
    private let buffer: PCMStreamBuffer

    init(sampleRate: Int) {
        self.sampleRate = sampleRate
        buffer = PCMStreamBuffer(capacity: sampleRate * 4 * 2)
    }

    func start() throws {
        let listener = try NWListener(using: .tcp)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                guard let address = Self.lanAddress(), let port = listener?.port?.rawValue,
                      let url = URL(string: "http://\(address):\(port)/\(self.token).wav") else {
                    self.fail("Could not find this Mac's local network address.")
                    return
                }
                self.onReady?(url)
            case .failed(let error): self.fail("Audio stream failed: \(error.localizedDescription)")
            default: break
            }
        }
        listener.start(queue: queue)
    }

    func setArtwork(_ data: Data?) {
        queue.async { [self] in artwork = data }
    }

    func append(_ pcm: Data) {
        guard !buffer.append(pcm) else { return }
        queue.async { [weak self] in
            self?.fail("The Wi-Fi connection could not keep up with audio. Casting stopped and Mac sound was restored. Move closer to the router and try again.")
        }
    }

    func stop() {
        buffer.deactivate()
        queue.async { [self] in close() }
    }

    private func close() {
        guard !stopped else { return }
        stopped = true
        buffer.deactivate()
        timer?.cancel()
        timer = nil
        receiver?.cancel()
        receiver = nil
        for request in requests.values { request.cancel() }
        requests.removeAll()
        listener?.cancel()
        listener = nil
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        close()
        onError?(message)
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, requests.count < 8 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        requests[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, !self.stopped else { return }
            switch state {
            case .ready: self.readRequest(on: connection, buffer: Data())
            case .failed(let error):
                self.requests.removeValue(forKey: id)
                if self.receiver === connection { self.fail("Speaker audio connection failed: \(error.localizedDescription)") }
            case .cancelled: self.requests.removeValue(forKey: id)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            guard let self, let connection, self.requests[id] != nil else { return }
            self.requests.removeValue(forKey: id)
            connection.cancel()
        }
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, done, error in
            guard let self, !self.stopped else { return }
            var request = buffer
            if let bytes { request.append(bytes) }
            guard request.count <= 16_384, error == nil else { connection.cancel(); return }
            guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
                if done { connection.cancel() } else { self.readRequest(on: connection, buffer: request) }
                return
            }
            self.requests.removeValue(forKey: ObjectIdentifier(connection))
            let path = text.components(separatedBy: " ").dropFirst().first?.components(separatedBy: "?").first
            if text.hasPrefix("GET "), path == "/\(self.token).wav.jpg", let artwork = self.artwork {
                let headers = "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: \(artwork.count)\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(headers.utf8) + artwork, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let get = text.hasPrefix("GET /\(self.token).wav ")
            let head = text.hasPrefix("HEAD /\(self.token).wav ")
            guard get || head else {
                self.replyAndClose("404 Not Found", on: connection)
                return
            }
            if head {
                self.replyAndClose("200 OK", on: connection)
                return
            }
            // Probes cannot cancel an existing stream; only a valid stream request replaces it.
            self.receiver?.cancel()
            self.buffer.deactivate()
            self.sending = false
            self.receiver = connection
            let headers = "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nTransfer-Encoding: chunked\r\nCache-Control: no-store\r\nAccept-Ranges: none\r\nConnection: keep-alive\r\n\r\n"
            var initial = Data(headers.utf8)
            initial.append(Self.chunk(Self.wavHeader(sampleRate: self.sampleRate)))
            connection.send(content: initial, completion: .contentProcessed { [weak self] error in
                guard let self, self.receiver === connection, !self.stopped else { return }
                if let error { self.fail("Could not start the audio stream: \(error.localizedDescription)"); return }
                self.buffer.activate()
                self.startSending()
                self.onReceiver?()
                self.watchDisconnect(connection)
            })
        }
    }

    private func replyAndClose(_ status: String, on connection: NWConnection) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: audio/wav\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func watchDisconnect(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, done, error in
            guard let self, self.receiver === connection, !self.stopped else { return }
            if done || error != nil { self.fail("The speaker closed its audio stream. Mac sound was restored.") }
            else { self.watchDisconnect(connection) }
        }
    }

    private func startSending() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.flush() }
        self.timer = timer
        timer.resume()
    }

    private func flush() {
        guard !stopped, !sending, let receiver else { return }
        let pcm = buffer.take(maxBytes: sampleRate * 4 / 50)
        guard !pcm.isEmpty else { return }
        sending = true
        receiver.send(content: Self.chunk(pcm), completion: .contentProcessed { [weak self] error in
            guard let self, self.receiver === receiver, !self.stopped else { return }
            self.sending = false
            if let error { self.fail("Speaker audio stream failed: \(error.localizedDescription)") }
            else { self.flush() }
        })
    }

    private static func chunk(_ data: Data) -> Data {
        var packet = Data(String(data.count, radix: 16).utf8)
        packet.append(contentsOf: [13, 10])
        packet.append(data)
        packet.append(contentsOf: [13, 10])
        return packet
    }

    private static func wavHeader(sampleRate: Int) -> Data {
        var data = Data("RIFF".utf8)
        func u16(_ value: UInt16) { data.append(contentsOf: [UInt8(value & 255), UInt8(value >> 8)]) }
        func u32(_ value: UInt32) { for shift in [0, 8, 16, 24] { data.append(UInt8((value >> shift) & 255)) } }
        u32(UInt32.max)
        data.append(contentsOf: "WAVEfmt ".utf8)
        u32(16); u16(1); u16(2)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 4)); u16(4); u16(16)
        data.append(contentsOf: "data".utf8)
        u32(UInt32.max - 36)
        return data
    }

    private static func lanAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        var addresses: [(String, String)] = []
        var current: UnsafeMutablePointer<ifaddrs>? = head
        while let item = current {
            let entry = item.pointee
            if let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
               entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 {
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.append((String(cString: entry.ifa_name), String(cString: name)))
                }
            }
            current = entry.ifa_next
        }
        return addresses.first(where: { $0.0 == "en0" })?.1 ?? addresses.first?.1
    }
}
