import AppKit
import Foundation

struct MusicTrack: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let position: Double
    let isPlaying: Bool
    var artwork: Data?
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

    func start() {
        queue.async { [self] in
            timer?.cancel()
            permissionDenied = false
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1)
            timer.setEventHandler { [weak self] in self?.refresh() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            artworkID = nil
            artwork = nil
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

    private func refresh() {
        guard !permissionDenied else { return }
        guard let result = execute("""
            if application id "com.apple.Music" is not running then return {}
            with timeout of 3 seconds
                tell application id "com.apple.Music"
                    if player state is stopped then return {}
                    set currentSongTrack to current track
                    return {persistent ID of currentSongTrack, name of currentSongTrack, artist of currentSongTrack, album of currentSongTrack, duration of currentSongTrack, player position, player state is playing}
                end tell
            end timeout
            """) else { onTrack?(nil); return }
        guard result.numberOfItems == 7 else {
            artworkID = nil
            artwork = nil
            onTrack?(nil)
            return
        }
        let id = result.atIndex(1)?.stringValue ?? ""
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
        onTrack?(MusicTrack(id: id, title: result.atIndex(2)?.stringValue ?? "",
                           artist: result.atIndex(3)?.stringValue ?? "", album: result.atIndex(4)?.stringValue ?? "",
                           duration: result.atIndex(5)?.doubleValue ?? 0,
                           position: result.atIndex(6)?.doubleValue ?? 0,
                           isPlaying: result.atIndex(7)?.booleanValue ?? false, artwork: artwork))
    }

    private func execute(_ source: String, reportError: Bool = true) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
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
