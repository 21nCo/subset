// swift-tools-version:6.0
import PackageDescription

// The package builds the reusable core and its tests with Command Line Tools alone, plus the menu-bar app
// executable for local runs. Releases use the generated Xcode project (ProjectGenerator.rb), which compiles the
// same Core and MacApp sources.
let package = Package(
    name: "SubsetSystem",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SystemCore", targets: ["SystemCore"])
    ],
    targets: [
        .target(
            name: "SystemCore",
            path: "Core"
        ),
        .executableTarget(
            name: "SubsetSystem",
            dependencies: ["SystemCore"],
            path: "MacApp",
            exclude: ["Info.plist", "SubsetSystem.entitlements"]
        ),
        .testTarget(
            name: "SystemCoreTests",
            dependencies: ["SystemCore"],
            path: "Tests/CoreTests"
        )
    ]
)
