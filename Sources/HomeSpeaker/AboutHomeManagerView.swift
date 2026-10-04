import AppKit
import SwiftUI

struct HomeManagerCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Home Manager") { openWindow(id: "about") }
        }
    }
}

struct AboutHomeManagerView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        return "Version \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 16) {
            if let url = Bundle.main.url(forResource: "HomeSpeakerIconSource", withExtension: "png"),
               let icon = NSImage(contentsOf: url) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 80, height: 80)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 5) {
                Text("Home Manager").font(.title2.weight(.bold))
                Text(version).font(.caption).foregroundStyle(.secondary)
            }
            Text("Created by Shudufhadzo Nemulalate")
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            VStack(spacing: 10) {
                Link("him@shudufhadzo.com", destination: URL(string: "mailto:him@shudufhadzo.com")!)
                Link("shudufhadzo.com", destination: URL(string: "https://shudufhadzo.com")!)
                    .accessibilityLabel("Shudufhadzo's portfolio, shudufhadzo.com")
            }
        }
        .padding(28)
        .frame(width: 390)
    }
}
