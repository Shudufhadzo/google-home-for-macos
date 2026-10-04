import HomeCore
import SwiftUI

struct AirPlayDestinationSection: View {
    @ObservedObject var model: SpeakerModel
    let devices: [HomeDevice]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Also play on an AirPlay TV", isOn: $model.includeAirPlay)
                .disabled(model.isCastingMacAudio || model.isRestoringAudio)
            if model.includeAirPlay {
                AirPlayOutputControls(model: model, output: model.airPlay, devices: devices)
            } else {
                Text("Add an AirPlay TV alongside your Cast speakers or Google Home group.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct AirPlayOutputControls: View {
    @ObservedObject var model: SpeakerModel
    @ObservedObject var output: AirPlayAudioPlayer
    let devices: [HomeDevice]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(output.routeName ?? "Choose AirPlay output").font(.subheadline.weight(.semibold))
                    Text(output.isAirPlayRouteSelected ? "AirPlay route selected" : "Use the AirPlay button to select your TV")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                AirPlayRoutePicker(player: output).frame(width: 44, height: 34)
            }
            if !devices.isEmpty {
                Text("Discovered: \(devices.map(\.name).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(model.isCastingMacAudio ? output.message : "Select your Cast speakers, start casting, then choose the TV here. In Music, choose this Mac as the output so Home Manager can capture it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Both outputs use the same audio at normal speed. AirPlay and Cast buffer separately; an audible delay can remain.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.isCastingMacAudio {
                Text(model.airPlayTimingMessage).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Stepper(value: $model.airPlayTimingOffset, in: -5...5, step: 0.1) {
                    Text("TV timing offset: \(model.airPlayTimingOffset, specifier: "%+.1f") s").font(.caption).monospacedDigit()
                }
                Text("Positive moves TV audio ahead; negative delays it. Apply while listening to both outputs.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Align TV to speakers") { model.alignAirPlay() }
                    .disabled(!model.canAlignAirPlay)
                Text("Adjust TV volume using the AirPlay picker or TV remote.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
