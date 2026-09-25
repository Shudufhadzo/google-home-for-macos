import Foundation

/// A bounded FIFO. Overload is a session failure, never a silent splice in the waveform.
final class PCMStreamBuffer {
    private let lock = NSLock()
    private var data = Data()
    private var active = false
    let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    func activate() {
        lock.lock(); defer { lock.unlock() }
        data.removeAll(keepingCapacity: true)
        active = true
    }

    func deactivate() {
        lock.lock(); defer { lock.unlock() }
        active = false
        data.removeAll(keepingCapacity: true)
    }

    /// Inactive buffers deliberately ignore startup audio, before the receiver requests it.
    func append(_ bytes: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active else { return true }
        guard data.count + bytes.count <= capacity else { return false }
        data.append(bytes)
        return true
    }

    func take(maxBytes: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        let count = min(maxBytes, data.count) / 4 * 4
        guard active, count > 0 else { return Data() }
        let packet = Data(data.prefix(count))
        data.removeFirst(count)
        return packet
    }
}
