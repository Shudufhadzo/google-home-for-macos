import Foundation

/// Estimates media timeline alignment only; receiver and TV acoustic delay is not measured.
enum MixedPlaybackTiming {
    struct Assessment {
        var target: Double?
        var difference: Double?
        var note: String
    }

    static func assess(statuses: [String: CastStatus], contentID: String, now: TimeInterval,
                       airPlayPosition: Double?, airPlaySampledAt: TimeInterval?, airPlayPlaying: Bool,
                       seekableRanges: [ClosedRange<Double>], offset: Double) -> Assessment {
        guard offset.isFinite, (-5...5).contains(offset) else {
            return Assessment(note: "Choose a TV timing offset between −5 and +5 seconds.")
        }
        guard now.isFinite, !contentID.isEmpty, !statuses.isEmpty else {
            return Assessment(note: "Waiting for every Cast destination's playback timing.")
        }
        var castPositions: [Double] = []
        for status in statuses.values {
            guard status.contentID == contentID, status.receiverAppID == "CC1AD845",
                  status.mediaSessionID != nil, status.playerState == "PLAYING",
                  let rate = status.playbackRate, rate.isFinite, abs(rate - 1) < 0.001,
                  let position = status.estimatedPosition(at: now), position >= 0 else {
                return Assessment(note: "Waiting for fresh timing at 1× on every selected Cast destination.")
            }
            castPositions.append(position)
        }
        guard airPlayPlaying, let airPlayPosition, airPlayPosition.isFinite, airPlayPosition >= 0,
              let airPlaySampledAt, airPlaySampledAt.isFinite,
              now >= airPlaySampledAt, now - airPlaySampledAt <= 3,
              let slowestCastPosition = castPositions.min() else {
            return Assessment(note: "Waiting for a fresh, advancing AirPlay playback position.")
        }
        let estimatedAirPlayPosition = airPlayPosition + (now - airPlaySampledAt)
        let difference = estimatedAirPlayPosition - slowestCastPosition
        let target = slowestCastPosition + offset
        guard estimatedAirPlayPosition.isFinite, difference.isFinite, target.isFinite else {
            return Assessment(note: "Playback timing is unavailable.")
        }
        guard seekableRanges.contains(where: { range in
            range.lowerBound.isFinite && range.upperBound.isFinite && range.lowerBound >= 0 &&
            target >= range.lowerBound + 0.1 && target <= range.upperBound - 0.1
        }) else {
            return Assessment(difference: difference, note: "Estimated media timing only. The adjustment is outside AirPlay's current live window.")
        }
        return Assessment(target: target, difference: difference,
                          note: "Apply this media timing adjustment manually. TV sound processing delay is not measured.")
    }
}
