// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pauline",
    platforms: [.macOS(.v14)],
    targets: [
        // Safety rules, battery reminders, and the menu and Telegram texts. Plain Swift, no system calls, unit tested.
        .target(name: "PaulineCore"),
        // The menu bar app: AppKit, IOKit, pmset and the Telegram client.
        .executableTarget(name: "Pauline", dependencies: ["PaulineCore"]),
        .testTarget(name: "PaulineCoreTests", dependencies: ["PaulineCore"]),
        .testTarget(name: "PaulineTests", dependencies: ["Pauline"]),
    ]
)
