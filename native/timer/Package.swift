// swift-tools-version:6.0
import PackageDescription

// The package builds the daemon client core and its tests with Command Line Tools alone.
let package = Package(
    name: "Timer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TimerCore", targets: ["TimerCore"])
    ],
    targets: [
        .target(name: "TimerCore", path: "Core"),
        .testTarget(
            name: "TimerCoreTests",
            dependencies: ["TimerCore"],
            path: "Tests/TimerCoreTests"
        )
    ]
)
