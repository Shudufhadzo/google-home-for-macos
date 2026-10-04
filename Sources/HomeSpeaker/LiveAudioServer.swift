import Foundation
import Network
import OSLog

/// In-memory HLS. Finite responses prevent the receiver building an arbitrary WAV buffer.
final class LiveAudioServer {
    var onReady: ((URL) -> Void)?
    var onError: ((String) -> Void)?
    var onReceiver: (() -> Void)?
    private let queue = DispatchQueue(label: "HomeSpeaker.LiveAudioServer")
    private let logger = Logger(subsystem: "za.shudu.homespeaker", category: "LiveAudio")
    private var listener: NWListener?
    private var requests: [ObjectIdentifier: NWConnection] = [:]
    private var timer: DispatchSourceTimer?
    private var encoder: LiveAudioEncoder?
    private var tvEncoder: LiveAudioEncoder?
    private var tvPlaylist: LiveAudioPlaylist?
    private var audioWritten = false
    private var tvWritten = false
    private var pendingPCM = Data()
    private var playlist: LiveAudioPlaylist
    private var stopped = false
    private var announced = false
    private var received = false
    private var lastAudioTime = ProcessInfo.processInfo.systemUptime
    private var lastSilenceTime = ProcessInfo.processInfo.systemUptime
    private var artwork: Data?
    private var url: URL?
    private let token = UUID().uuidString
    private let sampleRate: Int
    private let buffer: PCMStreamBuffer
    private let metadata: PlaybackMetadata
    private let includesTVVideo: Bool
    private let preferIPv6: Bool
    private var lastSegmentTime = ProcessInfo.processInfo.systemUptime

    init(sampleRate: Int, coordinatedStartup: Bool = false, metadata: PlaybackMetadata = .macAudio, includeTVVideo: Bool = false, preferIPv6: Bool = false) {
        self.sampleRate = sampleRate
        self.metadata = metadata
        includesTVVideo = includeTVVideo
        self.preferIPv6 = preferIPv6
        playlist = LiveAudioPlaylist(coordinatedStartup: coordinatedStartup)
        if includeTVVideo { tvPlaylist = LiveAudioPlaylist(coordinatedStartup: coordinatedStartup) }
        buffer = PCMStreamBuffer(capacity: sampleRate * 4)
    }

    func start() throws {
        let encoder = try LiveAudioEncoder(sampleRate: sampleRate, metadata: metadata)
        self.encoder = encoder
        encoder.onSegment = { [weak self] data, duration in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                if let duration {
                    self.playlist.append(data, duration: duration)
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - self.lastSegmentTime > 1.5 {
                        self.logger.warning("Audio fragment production delayed: \(now - self.lastSegmentTime) s, duration=\(duration)")
                    }
                    self.lastSegmentTime = now
                }
                else { self.playlist.initialization = data }
                self.announceIfReady()
            }
        }
        if tvPlaylist != nil {
            let tv = try LiveAudioEncoder(sampleRate: sampleRate, metadata: metadata, includeVideo: true)
            tvEncoder = tv
            tv.onSegment = { [weak self] data, duration in
                guard let self else { return }
                self.queue.async {
                    guard !self.stopped else { return }
                    if let duration { self.tvPlaylist?.append(data, duration: duration) }
                    else { self.tvPlaylist?.initialization = data }
                    self.announceIfReady()
                }
            }
        }
        let listener = try NWListener(using: .tcp)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                guard let address = Self.lanAddress(preferIPv6: self.preferIPv6), let port = listener?.port?.rawValue,
                      let url = URL(string: "http://\(address):\(port)/\(self.token)/live.m3u8") else {
                    self.fail("Could not find this Mac's local network address.")
                    return
                }
                self.url = url
                self.announceIfReady()
            case .failed(let error): self.fail("Audio stream failed: \(error.localizedDescription)")
            default: break
            }
        }
        buffer.activate()
        listener.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.encode() }
        self.timer = timer
        timer.resume()
    }

    private func announceIfReady() {
        guard !announced, playlist.isReady, tvPlaylist?.isReady != false, let url else { return }
        announced = true
        logger.notice("AAC live stream ready: half-second segments, 256 kbps stereo")
        onReady?(url)
    }

    func setArtwork(_ data: Data?) { queue.async { [self] in artwork = data } }

    /// Change the TV card without replacing the writer, playlist, or receiver URL.
    func updateNowPlaying(_ metadata: PlaybackMetadata) {
        do {
            let poster = includesTVVideo ? try NowPlayingPoster.make(metadata: metadata) : nil
            queue.async { [self] in
                guard !stopped else { return }
                artwork = metadata.artwork
                if let poster { tvEncoder?.updatePoster(poster) }
            }
        } catch { logger.error("Could not render the next TV card: \(error.localizedDescription, privacy: .public)") }
    }

    func finishCoordinatedStartup() { queue.async { [self] in playlist.finishCoordinatedStartup(); tvPlaylist?.finishCoordinatedStartup() } }

    func append(_ pcm: Data) {
        guard !buffer.append(pcm) else { return }
        queue.async { [weak self] in self?.fail("Audio encoding could not keep up. Casting stopped and Mac sound was restored.") }
    }

    private func encode() {
        guard !stopped, let encoder else { return }
        do {
            for _ in 0..<10 {
                let now = ProcessInfo.processInfo.systemUptime
                var silence = false
                if pendingPCM.isEmpty {
                    pendingPCM = buffer.take(maxBytes: sampleRate * 4 / 50)
                    if !pendingPCM.isEmpty { lastAudioTime = now; lastSilenceTime = now }
                    else if now - lastAudioTime >= 0.06, now - lastSilenceTime >= 0.019 {
                        // A process tap can stop delivering callbacks while its app is paused.
                        // Keep the HLS timeline live so the receiver does not abandon its loader.
                        let frames = min(sampleRate / 10, Int((now - lastSilenceTime) * Double(sampleRate)))
                        pendingPCM = Data(repeating: 0, count: frames * 4)
                        lastSilenceTime = now
                        silence = true
                    }
                }
                guard !pendingPCM.isEmpty else { return }
                if !audioWritten { audioWritten = try encoder.append(pendingPCM) }
                if let tvEncoder, !tvWritten { tvWritten = try tvEncoder.append(pendingPCM) }
                guard audioWritten, tvEncoder == nil || tvWritten else { return }
                pendingPCM.removeAll(keepingCapacity: true)
                audioWritten = false; tvWritten = false
                if silence { return }
            }
        } catch { fail("Audio encoding failed: \(error.localizedDescription)") }
    }

    func stop() {
        buffer.deactivate()
        queue.async { [self] in close() }
    }

    private func close() {
        guard !stopped else { return }
        stopped = true
        buffer.deactivate()
        timer?.cancel(); timer = nil
        encoder?.stop(); encoder = nil
        tvEncoder?.stop(); tvEncoder = nil
        for request in requests.values { request.cancel() }
        requests.removeAll()
        listener?.cancel(); listener = nil
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        close()
        onError?(message)
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, requests.count < 64 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        requests[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, !self.stopped else { return }
            switch state {
            case .ready: self.readRequest(on: connection, buffer: Data())
            case .failed, .cancelled: self.requests.removeValue(forKey: id)
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
            let parts = text.components(separatedBy: " ")
            let method = parts.first ?? ""
            let path = parts.dropFirst().first?.components(separatedBy: "?").first ?? ""
            let prefix = "/\(self.token)/"
            guard (method == "GET" || method == "HEAD"), path.hasPrefix(prefix) else {
                self.reply(on: connection, status: "404 Not Found", mime: "text/plain", data: Data()); return
            }
            let requestedFile = String(path.dropFirst(prefix.count))
            let isTV = requestedFile.hasPrefix("tv/")
            let file = isTV ? String(requestedFile.dropFirst(3)) : requestedFile
            let selectedPlaylist = isTV ? self.tvPlaylist : self.playlist
            self.logger.debug("HLS request: \(file, privacy: .public)")
            var data: Data?
            var mime = "audio/mp4"
            switch file {
            case "live.m3u8": data = selectedPlaylist?.manifest; mime = "application/vnd.apple.mpegurl"
            case "init.mp4": data = selectedPlaylist?.initialization
            case "live.m3u8.jpg": data = self.artwork; mime = "image/jpeg"
            default:
                if file.hasSuffix(".m4s"), let number = Int(file.dropLast(4)),
                   let segment = selectedPlaylist?.segments.first(where: { $0.number == number }) {
                    data = segment.data
                    if !self.received, method == "GET" {
                        self.received = true
                        self.logger.notice("Receiver requested first AAC media segment")
                        self.onReceiver?()
                    }
                }
            }
            if data == nil, file.hasSuffix(".m4s") {
                self.logger.error("Expired or missing HLS fragment \(file, privacy: .public); retained \(self.playlist.segments.first?.number ?? -1)...\(self.playlist.segments.last?.number ?? -1)")
            }
            self.reply(on: connection, status: data == nil ? "404 Not Found" : "200 OK", mime: mime,
                       data: data ?? Data(), head: method == "HEAD")
        }
    }

    private func reply(on connection: NWConnection, status: String, mime: String, data: Data, head: Bool = false) {
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8) + (head ? Data() : data), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func lanAddress(preferIPv6: Bool) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        var addresses: [(String, String)] = []
        var ipv6Addresses: [(String, String)] = []
        var current: UnsafeMutablePointer<ifaddrs>? = head
        while let item = current {
            let entry = item.pointee
            if let address = entry.ifa_addr,
               [sa_family_t(AF_INET), sa_family_t(AF_INET6)].contains(address.pointee.sa_family),
               entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 {
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let host = String(cString: name), interface = String(cString: entry.ifa_name)
                    if address.pointee.sa_family == sa_family_t(AF_INET) { addresses.append((interface, host)) }
                    else if !host.hasPrefix("fe80:"), !host.contains("%"), host != "::1" {
                        ipv6Addresses.append((interface, "[\(host)]"))
                    }
                }
            }
            current = entry.ifa_next
        }
        let ipv4 = addresses.first(where: { $0.0 == "en0" })?.1 ?? addresses.first?.1
        let ipv6 = ipv6Addresses.first(where: { $0.0 == "en0" })?.1 ?? ipv6Addresses.first?.1
        return preferIPv6 ? ipv6 ?? ipv4 : ipv4 ?? ipv6
    }
}
