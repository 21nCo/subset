// swift-tools-version:6.0
import PackageDescription

// The package builds SubsetCore (the app's logic) and its tests with Command Line Tools alone, plus the menu bar app
// executable for local runs. Releases use the generated Xcode project (ProjectGenerator.rb), which compiles the same
// Core and MacApp sources.
let package = Package(
    name: "Subset",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SubsetCore", targets: ["SubsetCore"])
    ],
    targets: [
        .target(
            name: "SubsetCore",
            path: "Core"
        ),
        .executableTarget(
            name: "Subset",
            dependencies: ["SubsetCore"],
            path: "MacApp",
            exclude: ["Info.plist", "Subset.entitlements"]
        ),
        .testTarget(
            name: "SubsetCoreTests",
            dependencies: ["SubsetCore"],
            path: "Tests/CoreTests"
        )
    ]
)
