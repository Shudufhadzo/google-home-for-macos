import SwiftUI

/// AirPlay is a destination alongside the Cast cards, with one selection control.
struct AirPlayDestinationSection: View {
    @ObservedObject var model: SpeakerModel
    @ObservedObject var output: AirPlayAudioPlayer
    let deviceName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Image(systemName: "airplay.audio")
                    .font(.title2)
                    .foregroundStyle(model.includeAirPlay ? Palette.blue : .secondary)
                Spacer()
                AirPlayRoutePicker(player: output)
                    .frame(width: 44, height: 34)
                    .disabled(!model.includeAirPlay)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(deviceName ?? "AirPlay")
                    .font(.headline).lineLimit(1)
                Text(output.isAirPlayRouteSelected ? "Connected" : "AirPlay")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Play with AirPlay", isOn: $model.includeAirPlay)
                .font(.caption)
                .disabled(model.isCastingMacAudio || model.isRestoringAudio)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(model.includeAirPlay ? Palette.blue : .clear, lineWidth: 1.5))
    }
}
