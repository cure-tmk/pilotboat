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
        .target(name: "ProcessKit"),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .testTarget(name: "ProcessKitTests", dependencies: ["ProcessKit"]),
    ]
)
