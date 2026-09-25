import AppKit
import SwiftUI

private enum Palette {
    static let blue = Color(red: 0.26, green: 0.46, blue: 0.88)
    static let navy = Color(red: 0.13, green: 0.21, blue: 0.35)
}

@main
struct HomeSpeakerApp: App {
    @StateObject private var model = SpeakerModel()

    var body: some Scene {
        WindowGroup("Home Speaker") {
            ContentView(model: model)
                .frame(minWidth: 680, minHeight: 640)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: SpeakerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                speakerSection
                playerSection
                audioSection
                statusLine
            }
            .padding(30)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Palette.blue)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
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
                Text("Home Speaker")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Music and sound around your home")
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
            heading("Speakers", detail: "Choose a Cast device on your Wi-Fi")
            if model.devices.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(Palette.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Looking for speakers").font(.headline)
                        Text("Keep your Mac and speaker on the same Wi-Fi network.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(18)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), spacing: 12)], spacing: 12) {
                    ForEach(model.devices) { device in speakerCard(device) }
                }
            }
        }
    }

    private func speakerCard(_ device: CastDevice) -> some View {
        let selected = model.selectedDevice?.id == device.id
        return Button { model.connect(to: device) } label: {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Image(systemName: device.model.localizedCaseInsensitiveContains("group") ? "hifispeaker.and.homepod.fill" : "hifispeaker.fill")
                        .font(.title2)
                        .foregroundStyle(selected ? Palette.blue : .secondary)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Palette.blue)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name).font(.headline).lineLimit(1)
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
        .accessibilityLabel("\(device.name), \(device.model), \(selected ? "selected" : "select speaker")")
    }

    private var playerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Now playing", detail: model.selectedDevice?.name ?? "Select a speaker above")
            HStack(spacing: 22) {
                Image(systemName: model.isPlaying ? "waveform" : "music.note")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.white)
                    .frame(width: 110, height: 110)
                    .background(LinearGradient(colors: [Palette.blue, Palette.navy], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.trackTitle.isEmpty ? "Nothing playing" : model.trackTitle)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .lineLimit(2)
                        Text(model.isCastingMacAudio ? "Live from this Mac" : (model.trackArtist.isEmpty ? "Start music on your phone or a Cast-enabled app" : model.trackArtist))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 18) {
                        transport("Previous track", symbol: "backward.end.fill", enabled: model.canSkipPrevious) { model.skipPrevious() }
                        transport(model.isPlaying ? "Pause" : "Play", symbol: model.isPlaying ? "pause.fill" : "play.fill", enabled: model.canControlPlayback, prominent: true) { model.togglePlayback() }
                        transport("Next track", symbol: "forward.end.fill", enabled: model.canSkipNext) { model.skipNext() }
                        transport("Stop", symbol: "stop.fill", enabled: model.canControlPlayback) { model.stopPlayback() }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
            HStack(spacing: 14) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.volume }, set: { model.setVolume($0) }), in: 0...1)
                    .disabled(model.selectedDevice == nil)
                    .accessibilityLabel("Speaker volume")
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

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Mac audio", detail: "Play sound from this Mac on your speaker")
            HStack(spacing: 16) {
                Image(systemName: "wifi")
                    .font(.title2).foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Palette.blue.gradient, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cast Mac audio over Wi-Fi").font(.headline)
                    Text("Stream Mac sound over Wi-Fi. Protected music may need Bluetooth.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(model.isCastingMacAudio ? "Stop casting" : "Cast Mac audio") {
                    if model.isCastingMacAudio { model.stopMacAudio() }
                    else { model.startMacAudio() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isConnected && !model.isCastingMacAudio)
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            HStack(spacing: 16) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.title2).foregroundStyle(Palette.blue)
                    .frame(width: 48, height: 48)
                    .background(Palette.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bluetooth audio").font(.headline)
                    Text("Pair once, then choose the speaker as an output.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Bluetooth settings") { model.openBluetoothSettings() }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            HStack {
                Picker("Sound output", selection: Binding(get: { model.selectedAudioOutput }, set: { model.selectAudioOutput($0) })) {
                    ForEach(model.audioOutputs) { output in Text(output.name).tag(output.id) }
                }
                Button { model.refreshAudioOutputs() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh sound outputs")
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
}
