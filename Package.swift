// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NotchClaw",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchClaw",
            path: "Sources/NotchClaw",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .testTarget(
            name: "NotchClawTests",
            dependencies: ["NotchClaw"],
            path: "Tests/NotchClawTests"
        ),
    ]
)
