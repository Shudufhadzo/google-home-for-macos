import Foundation

/// Seeks only on persistent drift in distinct, fresh reports. Keeps playback at 1×.
struct MixedDriftController {
    enum Correction: Equatable { case airPlay(Double), cast(Double) }
    static let tolerance = 0.08
    private var samples: [String: TimeInterval] = [:]
    private var rounds = 0
    private var lastCorrection = -Double.infinity
    private var seekLead = 0.0
    private var awaitingResult = false
    private var correctedCast = false

    mutating func reset() { self = Self() }

    mutating func target(assessment: MixedPlaybackTiming.Assessment?, sampleTimes: [String: TimeInterval],
                         offset: Double, now: TimeInterval) -> Correction? {
        guard let assessment, let difference = assessment.difference,
              offset.isFinite, now.isFinite, sampleTimes.count >= 2,
              sampleTimes.values.allSatisfy({ $0.isFinite && $0 <= now && now - $0 <= 3 }) else {
            rounds = 0; samples.removeAll(); return nil
        }
        guard sampleTimes.allSatisfy({ $0.value > (samples[$0.key] ?? -Double.infinity) }) else { return nil }
        samples = sampleTimes
        guard now - lastCorrection >= 4 else { rounds = 0; return nil }
        let error = difference - offset
        // Keep the TV's audio/video pipeline continuous when Cast seeking is
        // available. Alternating seeks between protocols can create a new gap.
        let correctingCast = assessment.castTarget != nil
        guard correctingCast || error >= 0 else { rounds = 0; return nil }
        guard let target = correctingCast ? assessment.castTarget : assessment.target else { rounds = 0; return nil }
        if awaitingResult {
            // Compensate command/buffering delay learned from the resulting media
            // position. This is not a measurement of the TV's acoustic latency.
            if correctedCast == correctingCast { seekLead = max(-1, min(1, seekLead + 0.35 * (correctedCast ? error : -error))) }
            else { seekLead = 0 }
            awaitingResult = false
        }
        rounds = abs(error) > Self.tolerance ? rounds + 1 : 0
        guard rounds >= 3 else { return nil }
        rounds = 0; lastCorrection = now; awaitingResult = true
        correctedCast = correctingCast
        return correctingCast ? .cast(target + seekLead) : .airPlay(target + seekLead)
    }
}
