// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DirectCanvas",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DirectCanvas",
            path: "Sources/DirectCanvas",
            resources: [.copy("Resources")]
        )
    ]
)
