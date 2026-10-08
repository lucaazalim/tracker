// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TrackerKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "TrackerKit", targets: ["TrackerKit"]),
    ],
    targets: [
        .target(
            name: "TrackerKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "TrackerKitTests",
            dependencies: ["TrackerKit"]
        ),
    ]
)
