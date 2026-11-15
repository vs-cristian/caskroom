// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Caskroom",
    platforms: [.macOS(.v26)],
    targets: [
        // Talks to the brew CLI and parses its JSON. No UI imports, unit-testable.
        .target(
            name: "BrewKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "CaskroomApp",
            dependencies: ["BrewKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // SUDO_ASKPASS for brew; make app copies it into Contents/Helpers.
        .executableTarget(
            name: "CaskroomAskpass",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BrewKitTests",
            dependencies: ["BrewKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
