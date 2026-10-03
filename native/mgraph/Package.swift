// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MGraphCapture",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MGraphCapture", targets: ["MGraphCapture"])],
    targets: [
        .target(name: "CaptureCore", path: "Sources/CaptureCore"),
        .executableTarget(name: "MGraphCapture", dependencies: ["CaptureCore"], path: "Sources/MGraphCapture"),
        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore"], path: "Tests/CaptureCoreTests")
    ]
)
