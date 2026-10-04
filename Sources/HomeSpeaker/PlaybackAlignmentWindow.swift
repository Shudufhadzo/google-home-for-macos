import Foundation

/// Calibration is allowed only while the source is held at startup or between
/// songs. Receiver positions are on the shared stream, not Music's source clock.
struct PlaybackAlignmentWindow {
    enum Phase: Equatable { case inactive, draining, aligning, finished }
    private(set) var phase: Phase = .inactive
    private(set) var corrections = 0
    private var tail: Double?
    private var deadline = 0.0
    private var lastCorrection = -Double.infinity
    private var stableRounds = 0
    private var samples: [String: Double] = [:]

    var needsInitialSeek: Bool { corrections == 0 }

    mutating func begin(at now: Double, drainingThrough tail: Double? = nil) {
        self = Self()
        self.tail = tail
        phase = tail == nil ? .aligning : .draining
        deadline = now + (tail == nil ? 12 : 45)
    }

    mutating func cancel() { self = Self() }

    /// Returns true when the gap is complete, including a bounded timeout when
    /// a receiver cannot supply usable timing. Never seek through an unfinished tail.
    mutating func observe(positions: [String: Double], sampleTimes: [String: Double],
                          expectedCount: Int, spread: Double?, now: Double) -> Bool {
        guard phase == .draining || phase == .aligning else { return phase == .finished }
        guard now < deadline else { phase = .finished; return true }
        guard expectedCount > 0, positions.count == expectedCount, sampleTimes.count == expectedCount,
              positions.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              sampleTimes.values.allSatisfy({ $0.isFinite && $0 <= now && now - $0 <= 3 }) else { return false }
        if phase == .draining {
            guard let tail, positions.values.allSatisfy({ $0 >= tail + 0.25 }) else { return false }
            phase = .aligning; deadline = now + 12
        }
        guard now - lastCorrection >= 4 else { return false }
        if corrections >= 2 { phase = .finished; return true }
        guard sampleTimes.allSatisfy({ $0.value > (samples[$0.key] ?? -Double.infinity) }) else { return false }
        samples = sampleTimes
        stableRounds = spread.map { $0.isFinite && abs($0) <= 0.1 } == true ? stableRounds + 1 : 0
        if stableRounds >= 3 { phase = .finished; return true }
        return false
    }

    func canCorrect(at now: Double) -> Bool {
        phase == .aligning && now < deadline && corrections < 2 && now - lastCorrection >= 4
    }

    mutating func corrected(at now: Double) {
        guard canCorrect(at: now) else { return }
        corrections += 1; lastCorrection = now; stableRounds = 0
    }
}
