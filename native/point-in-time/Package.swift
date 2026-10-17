// swift-tools-version:6.0
import PackageDescription

// The package builds the reusable core and its tests with Command Line Tools alone, plus the menu-bar app
// executable that scripts/build-app.sh bundles for local runs. Releases use the generated Xcode project
// (ProjectGenerator.rb), which compiles the same Core and MacApp sources.
let package = Package(
    name: "PointInTime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PointInTimeCore", targets: ["PointInTimeCore"])
    ],
    targets: [
        .target(
            name: "PointInTimeCore",
            path: "Core",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "PointInTime",
            dependencies: ["PointInTimeCore"],
            path: "MacApp",
            exclude: ["Assets.xcassets", "Info.plist", "PointInTime.entitlements"]
        ),
        .testTarget(
            name: "PointInTimeCoreTests",
            dependencies: ["PointInTimeCore"],
            path: "Tests/CoreTests"
        )
    ]
)
