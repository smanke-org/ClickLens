// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClickLens",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "ClickLensKit"),
        .executableTarget(name: "ClickLens", dependencies: ["ClickLensKit"]),
        .testTarget(name: "ClickLensKitTests", dependencies: ["ClickLensKit"]),
    ]
)
