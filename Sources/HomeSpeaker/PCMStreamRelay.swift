import Foundation

/// Atomically gates capture during track changes while leaving the native mute tap running.
final class PCMStreamRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var consumer: ((Data) -> Void)?

    func route(to consumer: ((Data) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        self.consumer = consumer
    }

    func append(_ pcm: Data) {
        lock.lock(); defer { lock.unlock() }
        consumer?(pcm)
    }
}
