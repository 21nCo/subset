// swift-tools-version:6.0
import PackageDescription

// The package builds the reusable core and its tests with Command Line Tools alone, plus the menu-bar app
// executable and the read-only `point-in-time` command that scripts/build-app.sh bundles for local runs. Releases use
// the generated Xcode project (ProjectGenerator.rb), which compiles the same Core, MacApp, and CLI sources.
let package = Package(
    name: "PointInTime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PointInTimeCore", targets: ["PointInTimeCore"]),
        .executable(name: "point-in-time", targets: ["point-in-time"])
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
        .executableTarget(
            name: "point-in-time",
            dependencies: ["PointInTimeCore"],
            path: "CLI"
        ),
        .testTarget(
            name: "PointInTimeCoreTests",
            dependencies: ["PointInTimeCore"],
            path: "Tests/CoreTests"
        )
    ]
)
