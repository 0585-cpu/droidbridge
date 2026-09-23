// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DroidBridgeUSB",
    platforms: [.macOS(.v14)],
    products: [.library(name: "DroidBridgeUSB", targets: ["DroidBridgeUSB"]),
               .executable(name: "USBChecks", targets: ["USBChecks"])],
    targets: [.target(name: "CAoaUSB", cSettings: [.headerSearchPath("vendor")]),
              .target(name: "DroidBridgeUSB", dependencies: ["CAoaUSB"]),
              .executableTarget(name: "USBChecks", dependencies: ["DroidBridgeUSB"])])
