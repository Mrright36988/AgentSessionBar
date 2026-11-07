// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentSessionBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DeckCore"),
        .executableTarget(name: "AgentSessionBar", dependencies: ["DeckCore"]),
        .testTarget(name: "DeckCoreTests", dependencies: ["DeckCore"]),
    ]
)
