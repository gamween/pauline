// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pauline",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure safety rules, no system calls, fully unit tested.
        .target(name: "PaulineCore"),
        // The menu bar app: AppKit for the button, IOKit and pmset for the system side.
        .executableTarget(name: "Pauline", dependencies: ["PaulineCore"]),
        .testTarget(name: "PaulineCoreTests", dependencies: ["PaulineCore"]),
    ]
)
