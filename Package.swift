// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "cs2swift",
    products: [
        .executable(name: "cs2swift", targets: ["cs2swift"]),
        .library(name: "CS2Swift", targets: ["CS2Swift"]),
    ],
    targets: [
        .target(name: "CS2Swift"),
        .executableTarget(name: "cs2swift", dependencies: ["CS2Swift"]),
        .testTarget(name: "CS2SwiftTests", dependencies: ["CS2Swift"]),
    ]
)
