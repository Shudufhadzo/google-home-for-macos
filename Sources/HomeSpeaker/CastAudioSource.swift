import CoreAudio
import Foundation

enum CastAudioSource: String, CaseIterable, Identifiable {
    case system = "All Mac audio"
    case appleMusic = "Apple Music"

    var id: String { rawValue }

    func tapDescription() throws -> CATapDescription {
        let description: CATapDescription
        switch self {
        case .system:
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .appleMusic:
            if #available(macOS 26.0, *) {
                description = CATapDescription(stereoMixdownOfProcesses: [])
                description.bundleIDs = ["com.apple.Music"]
                description.isProcessRestoreEnabled = true
            } else {
                let processes = try Self.musicProcesses()
                guard !processes.isEmpty else {
                    throw AudioTapError.unavailable("Start a song in Apple Music, then cast again.")
                }
                description = CATapDescription(stereoMixdownOfProcesses: processes)
            }
        }
        description.name = "Home Speaker — \(rawValue)"
        description.uuid = UUID()
        description.isPrivate = true
        // Core Audio restores local playback when the aggregate stops reading the tap.
        description.muteBehavior = .mutedWhenTapped
        return description
    }

    private static func musicProcesses() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard size > 0, AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }
        return processes.filter { process in
            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var bundleID: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(process, &bundleAddress, 0, nil, &bundleSize, &bundleID) == noErr else { return false }
            return bundleID?.takeUnretainedValue() as String? == "com.apple.Music"
        }
    }
}
