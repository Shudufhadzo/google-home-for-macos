import Darwin
import Foundation

/// A bounded SSDP M-SEARCH, with unicast replies read from the same ephemeral socket.
final class SSDPSearch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "za.shudu.homespeaker.ssdp")
    private var source: DispatchSourceRead?
    private var runID = UUID()
    var onData: (@Sendable (Data) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    private func report(_ operation: String, code: Int32) {
        onError?("\(operation): \(String(cString: strerror(code)))")
    }

    func start() {
        queue.async { [self] in
            source?.cancel(); source = nil
            runID = UUID()
            let run = runID
            let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard descriptor >= 0 else { report("socket", code: errno); return }
            var local = sockaddr_in()
            local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            local.sin_family = sa_family_t(AF_INET)
            local.sin_port = 0
            local.sin_addr.s_addr = INADDR_ANY
            let bound = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0 else { let code = errno; close(descriptor); report("bind", code: code); return }
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { let code = errno; close(descriptor); report("nonblocking socket", code: code); return }
            var ttl: UInt8 = 2
            _ = setsockopt(descriptor, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout.size(ofValue: ttl)))
            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = UInt16(1900).bigEndian
            destination.sin_addr.s_addr = inet_addr("239.255.255.250")
            let packet = Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 3\r\nST: ssdp:all\r\n\r\n".utf8)
            let sent = packet.withUnsafeBytes { bytes in
                withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent == packet.count else { let code = errno; close(descriptor); report("multicast send", code: code); return }
            let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            reader.setEventHandler { [weak self] in
                var bytes = [UInt8](repeating: 0, count: 16_385)
                // Limit work per wake so a noisy LAN cannot starve cancellation.
                for _ in 0..<32 {
                    let count = recv(descriptor, &bytes, bytes.count, 0)
                    guard count > 0 else { break }
                    if count <= 16_384 { self?.onData?(Data(bytes.prefix(count))) }
                }
            }
            reader.setCancelHandler { close(descriptor) }
            source = reader
            reader.resume()
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.runID == run else { return }
                self.source?.cancel(); self.source = nil
            }
        }
    }
    func stop() {
        queue.async { [self] in runID = UUID(); source?.cancel(); source = nil }
    }
    deinit { source?.cancel() }
}
