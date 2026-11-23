// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LiquidStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LiquidStudio",
            resources: [.copy("Resources")]
        )
    ]
)
