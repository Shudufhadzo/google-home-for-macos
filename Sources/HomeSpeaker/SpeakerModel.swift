import AppKit
import CoreAudio
import Foundation

struct CastDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let model: String
    let host: String
    let port: UInt16
}

struct AudioOutput: Identifiable {
    let id: AudioDeviceID
    let name: String
}

@MainActor
final class SpeakerModel: NSObject, ObservableObject {
    @Published private(set) var devices: [CastDevice] = []
    @Published private(set) var selectedDevice: CastDevice?
    @Published private(set) var trackTitle = ""
    @Published private(set) var trackArtist = ""
    @Published private(set) var isPlaying = false
    @Published private(set) var canControlPlayback = false
    @Published private(set) var canSkipNext = false
    @Published private(set) var canSkipPrevious = false
    @Published private(set) var isConnected = false
    @Published private(set) var isCastingMacAudio = false
    @Published private(set) var volume = 0.5
    @Published private(set) var audioOutputs: [AudioOutput] = []
    @Published private(set) var selectedAudioOutput: AudioDeviceID = 0
    @Published private(set) var message = "Ready to scan."

    private var browser: NetServiceBrowser?
    private var resolving: [String: NetService] = [:]
    private var client: CastClient?
    private var audioTap: SystemAudioTap?
    private var audioServer: LiveAudioServer?
    private var scanGeneration = 0

    func start() {
        scanAgain()
        refreshAudioOutputs()
    }

    func stop() {
        stopMacAudio()
        browser?.stop()
        browser = nil
        client?.disconnect()
        client = nil
    }

    func scanAgain() {
        scanGeneration += 1
        let generation = scanGeneration
        browser?.stop()
        devices.removeAll()
        resolving.removeAll()
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        browser.searchForServices(ofType: "_googlecast._tcp.", inDomain: "local.")
        message = "Searching for Cast speakers…"
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.scanGeneration == generation, self.devices.isEmpty else { return }
            self.message = "No Cast speakers found. Check Wi-Fi and Local Network access, then scan again."
        }
    }

    func connect(to device: CastDevice) {
        stopMacAudio()
        client?.disconnect()
        isConnected = false
        selectedDevice = device
        trackTitle = ""
        trackArtist = ""
        canControlPlayback = false
        canSkipNext = false
        canSkipPrevious = false
        message = "Connecting to \(device.name)…"
        let client = CastClient(device: device)
        client.onStatus = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.volume = status.volume
                self.isConnected = true
                self.trackTitle = status.title
                self.trackArtist = status.artist
                self.isPlaying = status.isPlaying
                self.canControlPlayback = status.mediaSessionID != nil
                self.canSkipNext = status.supportsNext
                self.canSkipPrevious = status.supportsPrevious
                if !self.isCastingMacAudio { self.message = "Connected to \(device.name)." }
            }
        }
        client.onError = { [weak self] error in
            Task { @MainActor [weak self] in self?.message = error }
        }
        client.onProgress = { [weak self] progress in
            Task { @MainActor [weak self] in self?.message = progress }
        }
        self.client = client
        client.connect()
    }

    func togglePlayback() {
        client?.setPlaying(!isPlaying)
    }

    func stopPlayback() {
        client?.stopPlayback()
    }

    func skipPrevious() {
        client?.skip(next: false)
    }

    func skipNext() {
        client?.skip(next: true)
    }

    func setVolume(_ value: Double) {
        volume = value
        client?.setVolume(value)
    }

    func startMacAudio() {
        guard isConnected, let client else {
            message = "Connect to a speaker before sending Mac audio."
            return
        }
        guard #available(macOS 14.4, *) else {
            message = "Mac audio casting requires macOS 14.4 or later."
            return
        }
        do {
            let tap = SystemAudioTap()
            try tap.start()
            let server = LiveAudioServer(sampleRate: tap.sampleRate)
            tap.onPCM = { [weak server] pcm in server?.append(pcm) }
            server.onReady = { [weak self, weak client] url in
                Task { @MainActor [weak self] in
                    guard let self, self.isCastingMacAudio else { return }
                    self.message = "Starting Mac audio on the speaker…"
                    client?.playMacAudio(at: url)
                }
            }
            server.onReceiver = { [weak self] in
                Task { @MainActor [weak self] in self?.message = "Mac audio is streaming to the speaker." }
            }
            server.onError = { [weak self] error in
                Task { @MainActor [weak self] in self?.message = error }
            }
            try server.start()
            audioTap = tap
            audioServer = server
            isCastingMacAudio = true
            message = "Waiting for the speaker to request Mac audio…"
        } catch {
            audioTap?.stop()
            audioTap = nil
            audioServer?.stop()
            audioServer = nil
            message = error.localizedDescription
        }
    }

    func stopMacAudio() {
        guard isCastingMacAudio else { return }
        audioTap?.stop()
        audioTap = nil
        audioServer?.stop()
        audioServer = nil
        isCastingMacAudio = false
        client?.stopPlayback()
        message = "Mac audio casting stopped."
    }

    func refreshAudioOutputs() {
        audioOutputs = AudioOutputManager.outputs()
        selectedAudioOutput = AudioOutputManager.defaultOutput()
    }

    func selectAudioOutput(_ id: AudioDeviceID) {
        if AudioOutputManager.setDefaultOutput(id) {
            selectedAudioOutput = id
            message = "Mac sound output changed."
        } else {
            message = "Could not change the Mac sound output."
            refreshAudioOutputs()
        }
    }

    func openBluetoothSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") else { return }
        NSWorkspace.shared.open(url)
    }

}

extension SpeakerModel: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            let key = service.name + service.domain
            resolving[key] = service
            service.delegate = self
            service.resolve(withTimeout: 8)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        Task { @MainActor in
            let key = service.name + service.domain
            resolving.removeValue(forKey: key)
            devices.removeAll { $0.id == key }
            if selectedDevice?.id == key {
                stopMacAudio()
                client?.disconnect()
                client = nil
                isConnected = false
                selectedDevice = nil
                canControlPlayback = false
                message = "Speaker went offline."
            }
        }
    }

    nonisolated func netServiceDidResolveAddress(_ service: NetService) {
        Task { @MainActor in
            let key = service.name + service.domain
            guard let resolvedHost = service.hostName, service.port > 0, service.port <= 65535 else { return }
            let host = service.addresses?.compactMap { address -> String? in
                address.withUnsafeBytes { bytes -> String? in
                    guard let pointer = bytes.baseAddress?.assumingMemoryBound(to: sockaddr.self),
                          pointer.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                    var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = getnameinfo(pointer, socklen_t(address.count), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST)
                    return result == 0 ? String(cString: name) : nil
                }
            }.first ?? resolvedHost
            let fields = service.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
            let name = fields["fn"].flatMap { String(data: $0, encoding: .utf8) } ?? service.name
            let model = fields["md"].flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let device = CastDevice(id: key, name: name, model: model, host: host, port: UInt16(service.port))
            devices.removeAll { $0.id == key }
            devices.append(device)
            devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            resolving.removeValue(forKey: key)
            message = "Found \(devices.count) Cast device\(devices.count == 1 ? "" : "s")."
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        Task { @MainActor in message = "Could not scan the local network. Check Local Network access in System Settings." }
    }
}

enum AudioOutputManager {
    static func outputs() -> [AudioOutput] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr else { return nil }
            guard let name else { return nil }
            return AudioOutput(id: id, name: name.takeUnretainedValue() as String)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func defaultOutput() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return 0 }
        return id
    }

    static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }
}
