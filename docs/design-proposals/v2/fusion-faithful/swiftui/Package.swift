// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ProRibbon",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ProRibbon",
            path: "Sources/ProRibbon",
            resources: [.copy("Resources/Icons"), .copy("Resources/Viewport")]
        )
    ]
)
