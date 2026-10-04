// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HomeSpeaker",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "HomeSpeaker", targets: ["HomeSpeaker"]),
        .library(name: "HomeCore", targets: ["HomeCore"])
    ],
    targets: [
        .target(name: "HomeCore"),
        .executableTarget(name: "HomeSpeaker", dependencies: ["HomeCore"]),
        .testTarget(name: "HomeSpeakerTests", dependencies: ["HomeSpeaker", "HomeCore"]),
        .testTarget(name: "HomeCoreTests", dependencies: ["HomeCore"])
    ],
    swiftLanguageVersions: [.v5]
)
