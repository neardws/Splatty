// swift-tools-version: 6.0
// Pure, platform-independent capture logic for Splatty.
// Used by the iOS app (as an Xcode framework target via XcodeGen) and testable
// standalone with `swift test` on macOS or Linux.
import PackageDescription

let package = Package(
    name: "SplattyCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "SplattyCore", targets: ["SplattyCore"]),
    ],
    targets: [
        .target(name: "SplattyCore"),
        .testTarget(name: "SplattyCoreTests", dependencies: ["SplattyCore"]),
    ]
)
