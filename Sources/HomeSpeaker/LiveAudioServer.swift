import Foundation
import Network

/// Serves a short-lived, unlisted HTTP stream directly to the selected Cast receiver.
final class LiveAudioServer {
    var onReady: ((URL) -> Void)?
    var onError: ((String) -> Void)?
    var onReceiver: (() -> Void)?

    private let queue = DispatchQueue(label: "HomeSpeaker.LiveAudioServer")
    private var listener: NWListener?
    private var receiver: NWConnection?
    private var pendingBytes = 0
    private var streaming = false
    private let token = UUID().uuidString
    private let sampleRate: Int

    init(sampleRate: Int) { self.sampleRate = sampleRate }

    func start() throws {
        let listener = try NWListener(using: .tcp)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let address = Self.lanAddress(), let port = listener.port?.rawValue,
                      let url = URL(string: "http://\(address):\(port)/\(self.token).wav") else {
                    self.onError?("Could not find this Mac's local network address.")
                    return
                }
                self.onReady?(url)
            case .failed(let error): self.onError?("Audio stream failed: \(error.localizedDescription)")
            default: break
            }
        }
        listener.start(queue: queue)
    }

    func append(_ pcm: Data) {
        queue.async { [weak self] in
            guard let self, self.streaming, let receiver = self.receiver,
                  self.pendingBytes < 512_000 else { return }
            self.sendChunk(pcm, on: receiver)
        }
    }

    func stop() {
        queue.async { [self] in
            receiver?.cancel()
            receiver = nil
            listener?.cancel()
            listener = nil
            streaming = false
        }
    }

    private func accept(_ connection: NWConnection) {
        receiver?.cancel()
        receiver = connection
        streaming = false
        pendingBytes = 0
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .ready = state, let connection { self?.readRequest(on: connection, buffer: Data()) }
        }
        connection.start(queue: queue)
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, done, error in
            guard let self, self.receiver === connection else { return }
            var request = buffer
            if let bytes { request.append(bytes) }
            guard request.count <= 16_384, !done, error == nil else { connection.cancel(); return }
            guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
                self.readRequest(on: connection, buffer: request)
                return
            }
            guard text.hasPrefix("GET /\(self.token).wav ") else {
                connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let headers = "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nTransfer-Encoding: chunked\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n"
            connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else { connection.cancel(); return }
                self.sendChunk(Self.wavHeader(sampleRate: self.sampleRate), on: connection)
                self.streaming = true
                self.onReceiver?()
            })
        }
    }

    private func sendChunk(_ data: Data, on connection: NWConnection) {
        var packet = Data(String(data.count, radix: 16).utf8)
        packet.append(contentsOf: [13, 10])
        packet.append(data)
        packet.append(contentsOf: [13, 10])
        pendingBytes += packet.count
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingBytes = max(0, self.pendingBytes - packet.count)
            if let error { self.onError?("Speaker audio stream closed: \(error.localizedDescription)") }
        })
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
