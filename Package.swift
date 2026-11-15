// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Singer",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Singer",
            path: "Sources/Singer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
