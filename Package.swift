// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pilotboat",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "Core"),
        .target(name: "ProcessKit"),
        .target(name: "Persistence", dependencies: ["Core", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .testTarget(name: "ProcessKitTests", dependencies: ["ProcessKit"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
    ]
)
