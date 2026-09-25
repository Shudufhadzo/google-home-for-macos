// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HomeSpeaker",
    platforms: [.macOS("14.4")],
    products: [.executable(name: "HomeSpeaker", targets: ["HomeSpeaker"])],
    targets: [.executableTarget(name: "HomeSpeaker")],
    swiftLanguageVersions: [.v5]
)
