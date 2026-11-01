// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pilotboat",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
    ],
    dependencies: [
    ],
    targets: [
        .target(name: "Core"),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
    ]
)
