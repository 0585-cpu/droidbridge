// swift-tools-version:6.0
import PackageDescription

// Note: tests run as an executable `Checks` target (assert-based) because Command Line Tools ship
// no XCTest. When full Xcode is available, these convert to the XCTest suite the plan describes.
let package = Package(
    name: "DroidBridgeShared",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DroidBridgeShared", targets: ["DroidBridgeShared"]),
        .executable(name: "Checks", targets: ["Checks"]),
    ],
    targets: [
        .target(
            name: "DroidBridgeShared",
            resources: [.copy("Resources/dbp-v1.json"), .copy("Resources/dbp-extensions.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Checks",
            dependencies: ["DroidBridgeShared"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
