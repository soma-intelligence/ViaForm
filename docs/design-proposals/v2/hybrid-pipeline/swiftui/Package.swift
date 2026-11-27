// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HybridPipeline",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HybridPipeline",
            path: "Sources/HybridPipeline",
            resources: [.copy("Resources/Art"), .copy("Resources/ToolIcons")]
        )
    ]
)
