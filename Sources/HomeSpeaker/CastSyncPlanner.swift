import Foundation

/// Cast positions describe the media timeline, not the sound leaving a device.
/// Only seek our live media, with fresh samples and an overlapping seekable window.
enum CastSyncPlanner {
    static let tolerance = 0.08
    struct Assessment {
        var spread: Double?
        var corrections: [String: Double] = [:]
        var note: String
    }

    static func assess(statuses: [String: CastStatus], contentID: String, at now: TimeInterval) -> Assessment {
        guard statuses.count > 1 else { return Assessment(note: "Waiting for all receiver timing reports.") }
        var positions: [String: Double] = [:]
        for (id, status) in statuses {
            guard status.contentID == contentID, status.receiverAppID == "CC1AD845", status.mediaSessionID != nil,
                  status.playerState == "PLAYING", let rate = status.playbackRate, abs(rate - 1) < 0.001,
                  let position = status.estimatedPosition(at: now) else {
                return Assessment(note: "Waiting for fresh playback timing at 1× on every destination.")
            }
            positions[id] = position
        }
        let earliest = positions.values.min()!, spread = positions.values.max()! - earliest
        guard let range = commonRange(statuses: statuses, contentID: contentID, at: now),
              range.lowerBound + 0.25 <= earliest, earliest <= range.upperBound - 0.25 else {
            return Assessment(spread: spread, note: "Live seeking is unavailable; use a Google Home group for tighter sync.")
        }
        let corrections = positions.filter { $0.value - earliest > tolerance }.mapValues { _ in earliest }
        return Assessment(spread: spread, corrections: corrections,
                          note: "Monitoring drift at 1×. Device audio processing can add delay.")
    }

    static func commonLiveAnchor(statuses: [String: CastStatus], contentID: String, at now: TimeInterval) -> Double? {
        guard let range = commonRange(statuses: statuses, contentID: contentID, at: now), range.upperBound - range.lowerBound > 0.5 else { return nil }
        return max(range.lowerBound + 0.25, range.upperBound - 1.5)
    }

    private static func commonRange(statuses: [String: CastStatus], contentID: String, at now: TimeInterval) -> ClosedRange<Double>? {
        guard !statuses.isEmpty else { return nil }
        var lower = 0.0, upper = Double.infinity
        for status in statuses.values {
            guard status.contentID == contentID, status.receiverAppID == "CC1AD845", status.mediaSessionID != nil,
                  status.supportsSeek, status.estimatedPosition(at: now) != nil,
                  let range = status.liveSeekableRange else { return nil }
            lower = max(lower, range.lowerBound); upper = min(upper, range.upperBound)
        }
        return lower < upper ? lower...upper : nil
    }
}
