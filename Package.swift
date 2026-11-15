// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Singer",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Singer",
            path: "Sources",
            sources: ["Shared", "Mac"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
