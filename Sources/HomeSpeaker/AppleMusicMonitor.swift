import AppKit
import Foundation
import OSLog

struct MusicTrack: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let position: Double
    let isPlaying: Bool
    var artwork: Data?
    var sampledAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    var atNaturalEnd = false
}

/// Uses Music's scripting dictionary; no private Now Playing framework or account login.
final class AppleMusicMonitor {
    enum Command: String { case playPause = "playpause", next = "next track", previous = "back track" }
    var onTrack: ((MusicTrack?) -> Void)?
    var onError: ((String) -> Void)?
    private let queue = DispatchQueue(label: "HomeSpeaker.AppleMusic")
    private var timer: DispatchSourceTimer?
    private var artworkID: String?
    private var artwork: Data?
    private var permissionDenied = false
    private let logger = Logger(subsystem: "za.shudu.homespeaker", category: "MusicSource")
    private var coordinated = false
    private var heldID: String?
    private var holdsSource = false
    private var naturalEnd = false
    private var armedBoundaryID: String?
    private var completedBoundaryID: String?
    private var latestTrack: MusicTrack?
    private var heldWasPlaying = false

    func start(coordinated: Bool = false) {
        queue.async { [self] in
            timer?.cancel()
            permissionDenied = false
            self.coordinated = coordinated
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(25))
            timer.setEventHandler { [weak self] in self?.refresh() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop(resumeHeld: Bool = true, advanceHeld: Command? = nil) {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            // Release only a source hold still owned by this session. Do not
            // replace Music's queue or replay a directly selected user track.
            if let id = heldID, holdsSource, resumeHeld, heldWasPlaying {
                let advance = advanceHeld?.rawValue ?? ""
                _ = execute("""
                    if application id "com.apple.Music" is running then
                        tell application id "com.apple.Music"
                            try
                                if persistent ID of current track is "\(id)" then
                                    \(advance)
                                    if \(advance.isEmpty ? "false" : "true") and player state is stopped and persistent ID of current track is "\(id)" then return
                                    play
                                end if
                            end try
                        end tell
                    end if
                    """, reportError: false)
            }
            heldID = nil; holdsSource = false; naturalEnd = false; armedBoundaryID = nil
            completedBoundaryID = nil; latestTrack = nil; coordinated = false
            artworkID = nil
            artwork = nil
        }
    }

    /// Pause the source before its first PCM enters the shared stream. The
    /// caller resumes only after every output has passed the startup barrier.
    func holdForStartup() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard timer != nil, let result = execute("""
                    if application id "com.apple.Music" is not running then return {"", false}
                    tell application id "com.apple.Music"
                        try
                            set sourceID to persistent ID of current track
                            set wasPlaying to player state is playing
                            pause
                            return {sourceID, wasPlaying}
                        on error
                            return {"", false}
                        end try
                    end tell
                    """) else {
                    continuation.resume(throwing: NSError(domain: "HomeSpeaker.Music", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Music could not be held for shared playback. Check Music Automation access."]))
                    return
                }
                guard let id = result.atIndex(1)?.stringValue, !id.isEmpty else {
                    continuation.resume(throwing: NSError(domain: "HomeSpeaker.Music", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Choose a song in Music before starting coordinated playback."]))
                    return
                }
                heldID = id
                holdsSource = true; naturalEnd = false
                let playing = result.atIndex(2)?.booleanValue ?? false
                heldWasPlaying = playing
                refresh()
                continuation.resume(returning: playing)
            }
        }
    }

    func holdForSkip(completion: @escaping () -> Void) {
        queue.async { [self] in
            guard timer != nil else { return }
            if let track = refresh(notify: false) { heldID = track.id }
            _ = execute("tell application id \"com.apple.Music\" to pause")
            holdsSource = true; naturalEnd = false
            heldWasPlaying = true
            refresh(); completion()
        }
    }

    /// `next track` uses Music's current queue; no playlist is reconstructed.
    /// Without a track change, a stopped last item is left stopped.
    func resumeHeld(advance: Command?, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            guard timer != nil else { return }
            let previousID = heldID ?? ""
            let completedNaturalBoundary = naturalEnd
            let advanceSource = advance?.rawValue ?? ""
            let result = execute("""
                tell application id "com.apple.Music"
                    try
                        if persistent ID of current track is not "\(previousID)" then return false
                        \(advanceSource)
                        if \(advance == nil ? "false" : "true") and player state is stopped and persistent ID of current track is "\(previousID)" then return false
                        play
                        return true
                    on error
                        return false
                    end try
                end tell
                """)
            holdsSource = false; naturalEnd = false; heldID = nil; armedBoundaryID = nil
            let resumed = result?.booleanValue ?? false
            if resumed {
                completedBoundaryID = completedNaturalBoundary && advance == nil ? previousID : nil
                refresh(notify: false)
            }
            refresh(); completion(resumed)
        }
    }

    func command(_ command: Command) {
        queue.async { [self] in
            guard !permissionDenied, timer != nil else { return }
            _ = execute("""
                if application id "com.apple.Music" is running then
                    with timeout of 3 seconds
                        tell application id "com.apple.Music" to \(command.rawValue)
                    end timeout
                end if
                """)
            refresh()
        }
    }

    @discardableResult
    private func refresh(notify: Bool = true) -> MusicTrack? {
        guard !permissionDenied else { return nil }
        if coordinated, !holdsSource, let previous = latestTrack,
           previous.id == armedBoundaryID, previous.id != completedBoundaryID,
           previous.isPlaying, previous.duration > 0, previous.duration - previous.position <= 1.5,
           let fast = probeBoundary(previous), fast.id == previous.id {
            latestTrack = fast
            if notify { onTrack?(fast) }
            return fast
        }
        let canHold = coordinated && !holdsSource && armedBoundaryID != nil && armedBoundaryID != completedBoundaryID
        guard let result = execute("""
            if application id "com.apple.Music" is not running then return {}
            with timeout of 3 seconds
                tell application id "com.apple.Music"
                    set currentSongTrack to current track
                    set heldAtBoundary to false
                    if \(canHold ? "true" : "false") and player state is playing and persistent ID of currentSongTrack is "\(armedBoundaryID ?? "")" then
                        if duration of currentSongTrack > 0 and player position >= (duration of currentSongTrack) - 0.1 then
                            pause
                            set heldAtBoundary to true
                        end if
                    end if
                    return {persistent ID of currentSongTrack, name of currentSongTrack, artist of currentSongTrack, album of currentSongTrack, duration of currentSongTrack, player position, player state is playing, heldAtBoundary}
                end tell
            end timeout
            """) else { if notify { onTrack?(nil) }; return nil }
        let sampledAt = ProcessInfo.processInfo.systemUptime
        guard result.numberOfItems == 8 else {
            artworkID = nil
            artwork = nil
            if notify { onTrack?(nil) }
            return nil
        }
        let id = result.atIndex(1)?.stringValue ?? ""
        let playing = result.atIndex(7)?.booleanValue ?? false
        let heldAtBoundary = result.atIndex(8)?.booleanValue ?? false
        if id == completedBoundaryID, playing, let previous = latestTrack,
           previous.id == id, (result.atIndex(6)?.doubleValue ?? 0) < previous.position - 1 {
            // Repeat-one or a user rewind starts a new pass through this song.
            completedBoundaryID = nil
        }
        if holdsSource, let heldID, id != heldID, playing {
            // A direct user selection in Music takes over this hold.
            holdsSource = false; self.heldID = nil; naturalEnd = false; armedBoundaryID = nil
        }
        if heldAtBoundary {
            holdsSource = true; heldID = id; naturalEnd = true
            heldWasPlaying = true
            logger.notice("Music held at its final fraction; finishing the owned track after quiet-gap calibration")
        }
        if coordinated, playing, !holdsSource, id != completedBoundaryID {
            // Music currently ignores its documented `once` parameter. Use a
            // short boundary probe instead, then resume that final tail
            // and let Music advance its own queue normally after calibration.
            armedBoundaryID = id
        }
        if id == completedBoundaryID { armedBoundaryID = nil }
        else { completedBoundaryID = nil }
        if coordinated, playing, !holdsSource,
           let duration = result.atIndex(5)?.doubleValue,
           let position = result.atIndex(6)?.doubleValue, duration - position <= 1.5 {
            timer?.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25), leeway: .milliseconds(2))
        } else {
            timer?.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(25))
        }
        if id != artworkID {
            artworkID = id
            artwork = nil
            // Artwork is optional. A missing cover must not hide the song details.
            let cover = execute("""
                with timeout of 2 seconds
                    tell application id "com.apple.Music"
                        try
                            return raw data of artwork 1 of current track
                        on error
                            return missing value
                        end try
                    end tell
                end timeout
                """, reportError: false)
            if let data = cover?.data, data.count < 8_000_000, NSImage(data: data) != nil { artwork = data }
        }
        var track = MusicTrack(id: id, title: result.atIndex(2)?.stringValue ?? "",
                           artist: result.atIndex(3)?.stringValue ?? "", album: result.atIndex(4)?.stringValue ?? "",
                           duration: result.atIndex(5)?.doubleValue ?? 0,
                           position: result.atIndex(6)?.doubleValue ?? 0,
                           isPlaying: result.atIndex(7)?.booleanValue ?? false, artwork: artwork)
        track.sampledAt = sampledAt; track.atNaturalEnd = naturalEnd
        latestTrack = track
        if notify { onTrack?(track) }
        return track
    }

    /// Full metadata queries can span the final fraction of a song. Near the
    /// end, read only the clock/state/identity and perform an identity-guarded
    /// pause in the same event. A 350 ms lead covers Music's command latency and end-time reporting error;
    /// the remaining tail resumes afterward instead of being discarded.
    private func probeBoundary(_ previous: MusicTrack) -> MusicTrack? {
        guard let result = execute("""
            tell application id "com.apple.Music"
                set songID to persistent ID of current track
                set sourcePosition to player position
                set sourcePlaying to player state is playing
                set heldAtBoundary to false
                if songID is "\(previous.id)" and sourcePlaying and sourcePosition >= \(previous.duration - 0.35) then
                    pause
                    set sourcePlaying to false
                    set heldAtBoundary to true
                end if
                return {songID, sourcePosition, sourcePlaying, heldAtBoundary}
            end tell
            """), result.numberOfItems == 4 else { return nil }
        var track = previous
        guard result.atIndex(1)?.stringValue == track.id else { return nil }
        // Keep immutable metadata, with a fresh position/state snapshot.
        track = MusicTrack(id: track.id, title: track.title, artist: track.artist,
            album: track.album, duration: track.duration, position: result.atIndex(2)?.doubleValue ?? 0,
            isPlaying: result.atIndex(3)?.booleanValue ?? false, artwork: track.artwork)
        if result.atIndex(4)?.booleanValue == true {
            holdsSource = true; heldID = track.id; naturalEnd = true; heldWasPlaying = true
            logger.notice("Music's final fraction held for quiet-gap calibration; queue retained")
        }
        track.atNaturalEnd = naturalEnd
        timer?.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25), leeway: .milliseconds(2))
        return track
    }

    private func execute(_ source: String, reportError: Bool = true) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if reportError { logger.error("Music scripting error \(code): \(error[NSAppleScript.errorMessage] as? String ?? "unknown", privacy: .public)") }
            if code == -1743 { permissionDenied = true }
            if reportError {
                onError?(code == -1743
                         ? "Allow Home Speaker to access Music in System Settings → Privacy & Security → Automation to show songs and use track controls."
                         : "Music information is unavailable. \(error[NSAppleScript.errorMessage] as? String ?? "Try again when Music is playing.")")
            }
            return nil
        }
        return result
    }
}
