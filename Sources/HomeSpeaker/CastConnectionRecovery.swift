import Foundation

/// Retry only the control socket of a stream owned by this app, never another cast.
struct CastConnectionRecovery {
    private var attempts = 0
    private var lastFailure = -Double.infinity

    mutating func reset() { self = Self() }

    mutating func retryDelay(at now: TimeInterval, ownsActiveStream: Bool) -> TimeInterval? {
        guard ownsActiveStream, now.isFinite else { return nil }
        if now - lastFailure > 30 { attempts = 0 }
        lastFailure = now
        guard attempts < 3 else { return nil }
        let delay = [0.5, 1.0, 2.0][attempts]
        attempts += 1
        return delay
    }
}
