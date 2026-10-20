// swift-tools-version:6.0
import PackageDescription

// The package builds the reusable core and its tests with Command Line Tools alone, plus the menu-bar app
// executable for local runs. Releases use the generated Xcode project (ProjectGenerator.rb), which compiles the
// same Core and MacApp sources.
let package = Package(
    name: "Hop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HopCore", targets: ["HopCore"])
    ],
    targets: [
        .target(
            name: "HopCore",
            path: "Core"
        ),
        .executableTarget(
            name: "Hop",
            dependencies: ["HopCore"],
            path: "MacApp",
            exclude: ["Info.plist", "Hop.entitlements"]
        ),
        .testTarget(
            name: "HopCoreTests",
            dependencies: ["HopCore"],
            path: "Tests/CoreTests"
        ),
        // Inspects the app's views (the switcher panel's accessibility tree) without a window server session. SwiftPM
        // only: the Xcode project's test bundle covers HopCore.
        .testTarget(
            name: "HopAppTests",
            dependencies: ["Hop", "HopCore"],
            path: "Tests/AppTests"
        )
    ]
)
