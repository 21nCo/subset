// swift-tools-version:6.0
import PackageDescription

// The package builds the daemon client core and its tests with Command Line Tools alone, plus the menu bar app
// executable. Releases use the generated Xcode project (ProjectGenerator.rb), which compiles the same Core and
// MacApp sources and embeds the Timer CLI runtime.
let package = Package(
    name: "Timer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TimerCore", targets: ["TimerCore"])
    ],
    targets: [
        .target(name: "TimerCore", path: "Core"),
        .executableTarget(
            name: "TimerApp",
            dependencies: ["TimerCore"],
            path: "MacApp",
            exclude: ["Assets.xcassets", "Info.plist"]
        ),
        .testTarget(
            name: "TimerCoreTests",
            dependencies: ["TimerCore"],
            path: "Tests/TimerCoreTests"
        ),
        .testTarget(
            name: "TimerAppTests",
            dependencies: ["TimerApp", "TimerCore"],
            path: "Tests/TimerAppTests"
        )
    ]
)
