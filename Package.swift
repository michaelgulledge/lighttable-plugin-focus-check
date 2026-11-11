// swift-tools-version: 6.1
import Foundation
import PackageDescription

// The plugin compiles against the Light Table checkout in LIGHTTABLE_ROOT (scripts/build.sh sets it).
// Run from a bare clone, it expects Light Table next to this repository.
let host = ProcessInfo.processInfo.environment["LIGHTTABLE_ROOT"] ?? "../lighttable"

let package = Package(name: "LightTableFocusCheck", platforms: [.macOS(.v14)], products: [
  .executable(name: "FocusCheckPlugin", targets: ["FocusCheckPlugin"]),
], dependencies: [
  .package(name: "lighttable", path: host),
], targets: [
  .executableTarget(name: "FocusCheckPlugin", dependencies: [.product(name: "LightTablePluginKit", package: "lighttable"), .product(name: "LightTableCore", package: "lighttable")]),
  .testTarget(name: "PluginTests", dependencies: ["FocusCheckPlugin", .product(name: "LightTablePluginKit", package: "lighttable"), .product(name: "LightTableCore", package: "lighttable")]),
], swiftLanguageModes: [.v5])
