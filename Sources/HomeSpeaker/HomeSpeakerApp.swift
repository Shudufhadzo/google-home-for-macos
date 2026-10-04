import AppKit
import HomeCore
import SwiftUI

private enum Palette {
    static let blue = Color(red: 0.26, green: 0.46, blue: 0.88)
    static let navy = Color(red: 0.13, green: 0.21, blue: 0.35)
}

@main
struct HomeSpeakerApp: App {
    @StateObject private var model = SpeakerModel()
    @State private var home = HomeModel()

    var body: some Scene {
        Window("Home Manager", id: "home") {
            HomeDashboardView(home: home, speaker: model)
                .frame(minWidth: 820, minHeight: 640)
                .onAppear { model.start(); home.start() }
                .onDisappear { model.stop(); home.stop() }
        }
        .defaultSize(width: 1180, height: 780)
    }
}

struct ContentView: View {
    @ObservedObject var model: SpeakerModel
    var home: HomeModel

    private var displayDestinationNames: String {
        (model.selectedDevices.map { home.displayName(for: $0) } +
         (model.includeAirPlay ? [model.airPlay.routeName ?? "AirPlay TV"] : [])).joined(separator: ", ")
    }

    var body: some View {
        GeometryReader { geometry in
            let expanded = geometry.size.width >= 1040
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    if expanded {
                        HStack(alignment: .top, spacing: 28) {
                            VStack(alignment: .leading, spacing: 26) {
                                speakerSection
                                audioSection
                            }
                            .frame(width: min(420, (geometry.size.width - 64) * 0.36))
                            playerSection(expanded: true, height: max(510, geometry.size.height - 192))
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        speakerSection
                        playerSection()
                        audioSection
                    }
                    compatibilitySection
                    statusLine
                }
                .padding(expanded ? 32 : 24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Palette.blue)
    }

    private var header: some View {
        HStack(spacing: 16) {
            if let url = Bundle.main.url(forResource: "HomeSpeakerIconSource", withExtension: "png"),
               let icon = NSImage(contentsOf: url) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "hifispeaker.fill")
                    .font(.system(size: 25))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Palette.blue.gradient, in: RoundedRectangle(cornerRadius: 17))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Music & speakers")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Cast playback and sound from this Mac")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.scanAgain() } label: {
                Label("Scan", systemImage: "arrow.clockwise")
            }
        }
    }

    private var speakerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Destinations", detail: model.selectedDevices.isEmpty ? "Select one or more" : "\(model.selectedDevices.count) selected")
            if model.devices.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(Palette.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Looking for Cast destinations").font(.headline)
                        Text("Keep your Mac and receivers on the same Wi-Fi network.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(18)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 12)], spacing: 12) {
                    ForEach(model.devices) { device in speakerCard(device) }
                }
            }
            Text(model.isCastingMacAudio ? "Stop casting to change destinations." : "Select individual speakers and Cast TVs together, or choose one Google Home group. A group replaces individual selections and handles synchronisation.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.selectedDevices.isEmpty { destinationControls }
            Button("Google Home group setup") { home.open(URL(string: "https://support.google.com/googlehome/answer/7174267?hl=en")!) }
                .font(.caption)
            AirPlayDestinationSection(model: model, deviceNames: home.networkDevices.filter { $0.capabilities.contains(.airPlay) }.map { home.displayName(for: $0) })
        }
    }

    private func speakerCard(_ device: CastDevice) -> some View {
        let selected = model.selectedDevices.contains { $0.id == device.id }
        return Button { model.toggleDestination(device) } label: {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Image(systemName: device.isGroup ? "hifispeaker.and.homepod.fill" : (device.model.localizedCaseInsensitiveContains("TV") || device.model.localizedCaseInsensitiveContains("Chromecast") ? "tv.fill" : "hifispeaker.fill"))
                        .font(.title2)
                        .foregroundStyle(selected ? Palette.blue : .secondary)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Palette.blue)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(home.displayName(for: device)).font(.headline).lineLimit(1)
                    Text(device.model.isEmpty ? "Google Cast" : device.model)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 105, alignment: .leading)
            .background(selected ? Palette.blue.opacity(0.10) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(selected ? Palette.blue.opacity(0.8) : Color.secondary.opacity(0.15), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .disabled(model.isCastingMacAudio || model.isRestoringAudio)
        .accessibilityLabel("\(home.displayName(for: device)), \(device.model), \(selected ? "selected, remove destination" : "add destination")")
    }

    private var destinationControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.selectedDevices) { device in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(home.displayName(for: device)).font(.subheadline.weight(.semibold))
                        Spacer()
                        Button { model.removeDestination(device) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).disabled(model.isCastingMacAudio || model.isRestoringAudio)
                            .accessibilityLabel("Remove \(home.displayName(for: device))")
                    }
                    Text(model.destinationState(device))
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { model.receiverStatuses[device.id]?.volume ?? 0.5 }, set: { model.setVolume($0, for: device) }), in: 0...1)
                        .disabled(!model.connectedDeviceIDs.contains(device.id))
                        .accessibilityLabel("\(home.displayName(for: device)) volume")
                }
            }
            if !model.syncMessage.isEmpty {
                Text(model.syncMessage).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).monospacedDigit()
                if model.hasMultipleDestinations {
                    Button("Align playback now") { model.alignDestinations() }.disabled(!model.canAlign)
                        .help("Align fresh receiver positions when every device supports live seeking")
                }
            }
        }
        .padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private var otherTVs: [HomeDevice] {
        let castHosts = Set(model.devices.map(\.host))
        return home.networkDevices.filter {
            $0.kind == .television && !$0.capabilities.contains(.airPlay) && !($0.host.map(castHosts.contains) ?? false)
        }
    }

    @ViewBuilder
    private var compatibilitySection: some View {
        if !otherTVs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Other TVs & media devices").font(.headline)
                ForEach(otherTVs) { device in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "tv").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(home.displayName(for: device)).font(.subheadline.weight(.semibold))
                            Text("UPnP media device · Cast or AirPlay playback not advertised")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("These devices need a compatible playback receiver or home-hub integration.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func playerSection(expanded: Bool = false, height: CGFloat = 0) -> some View {
        let artworkSize = expanded ? min(360, max(200, height * 0.43)) : 110
        let layout = expanded ? AnyLayout(VStackLayout(alignment: .center, spacing: 24))
                              : AnyLayout(HStackLayout(alignment: .center, spacing: 22))
        return VStack(alignment: .leading, spacing: 12) {
            heading("Now playing", detail: displayDestinationNames.isEmpty ? "Select destinations" : displayDestinationNames)
            layout {
                Group {
                    if let data = model.musicTrack?.artwork, let cover = NSImage(data: data) {
                        Image(nsImage: cover).resizable().scaledToFill()
                    } else if let url = model.speakerArtworkURL {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() }
                            else { artworkPlaceholder(expanded: expanded) }
                        }
                        .id(url)
                    } else {
                        artworkPlaceholder(expanded: expanded)
                    }
                }
                    .frame(width: artworkSize, height: artworkSize)
                    .background(LinearGradient(colors: [Palette.blue, Palette.navy], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .accessibilityHidden(true)
                VStack(alignment: expanded ? .center : .leading, spacing: expanded ? 22 : 10) {
                    VStack(alignment: expanded ? .center : .leading, spacing: 6) {
                        Text(model.trackTitle.isEmpty ? "Nothing playing" : model.trackTitle)
                            .font(.system(size: expanded ? 28 : 22, weight: .semibold, design: .rounded))
                            .multilineTextAlignment(expanded ? .center : .leading)
                            .lineLimit(2)
                        Text(model.trackArtist.isEmpty ? "Start music on your phone or a Cast-enabled app" : model.trackArtist)
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        if let track = model.musicTrack, model.isCastingMacAudio, track.duration > 0 {
                            ProgressView(value: min(max(track.position, 0), track.duration), total: track.duration)
                                .accessibilityLabel("Song progress")
                            Text("\(durationText(track.position)) / \(durationText(track.duration)) · Apple Music")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: expanded ? 26 : 18) {
                        transport("Previous track", symbol: "backward.end.fill", enabled: model.canSkipPrevious) { model.skipPrevious() }
                        transport(model.isPlaying ? "Pause" : "Play", symbol: model.isPlaying ? "pause.fill" : "play.fill", enabled: model.canControlPlayback, prominent: true) { model.togglePlayback() }
                        transport("Next track", symbol: "forward.end.fill", enabled: model.canSkipNext) { model.skipNext() }
                        transport("Stop", symbol: "stop.fill", enabled: model.canStop) { model.stopPlayback() }
                    }
                }
                .frame(maxWidth: expanded ? 480 : .infinity)
                if !expanded { Spacer(minLength: 0) }
            }
            .padding(expanded ? 28 : 20)
            .frame(maxWidth: .infinity, minHeight: expanded ? height - 64 : nil, alignment: .center)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
            HStack(spacing: 14) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.volume }, set: { model.setVolume($0) }), in: 0...1)
                    .disabled(!model.isConnected)
                    .accessibilityLabel("All destinations volume")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                Text("\(Int(model.volume * 100))%")
                    .monospacedDigit().font(.caption).frame(width: 36, alignment: .trailing)
            }
            .padding(.horizontal, 4)
        }
    }

    private func transport(_ title: String, symbol: String, enabled: Bool, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 20 : 16, weight: .semibold))
                .frame(width: prominent ? 46 : 36, height: prominent ? 46 : 36)
                .background(prominent ? Palette.blue : .clear, in: Circle())
                .foregroundStyle(prominent ? .white : .primary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
        .help(title)
    }

    private func artworkPlaceholder(expanded: Bool) -> some View {
        Image(systemName: model.isPlaying ? "waveform" : "music.note")
            .font(.system(size: expanded ? 64 : 34, weight: .light))
            .foregroundStyle(.white)
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Mac audio", detail: "One audio stream to every destination")
            Picker("Cast from", selection: $model.castSource) {
                ForEach(CastAudioSource.allCases) { source in Text(source.rawValue).tag(source) }
            }
            .pickerStyle(.segmented)
            .disabled(model.isCastingMacAudio)
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "wifi")
                        .font(.title2).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Palette.blue.gradient, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cast over Wi-Fi").font(.headline)
                        Text(model.isCastingMacAudio ? model.audioQuality : (model.castSource == .appleMusic ? "Only Music is sent to every selected destination. Other Mac sound stays local." : "All Mac audio is sent to every selected destination."))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.isCastingMacAudio {
                            Label(model.audioCaptureStarted ? "Local playback muted" : "Waiting for recording permission…", systemImage: model.audioCaptureStarted ? "speaker.slash.fill" : "hourglass")
                                .font(.caption).foregroundStyle(.secondary)
                            if model.audioCaptureStarted {
                                Label(model.audioSignalDetected ? "Audio signal detected" : "Waiting for an audio signal from the source…", systemImage: model.audioSignalDetected ? "waveform" : "waveform.slash")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    if model.isCastingMacAudio { model.stopMacAudio() }
                    else { model.startMacAudio() }
                } label: {
                    Text(model.isCastingMacAudio ? "Stop casting" : "Cast Mac audio")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isRestoringAudio || (!model.isConnected && !model.isCastingMacAudio))
            }
            .padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            if !model.musicMessage.isEmpty {
                HStack {
                    Text(model.musicMessage).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry Music info") { model.retryMusicInfo() }
                }
            }

        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle().fill(model.selectedDevice == nil ? Color.secondary : Palette.blue)
                .frame(width: 7, height: 7)
            Text(model.message).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("Local network").font(.caption).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private func heading(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 19, weight: .semibold, design: .rounded))
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func durationText(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, Int(seconds)) : 0
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
