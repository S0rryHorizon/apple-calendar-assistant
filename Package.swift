// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "CalendarBridge",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "CalendarBridgeCore", targets: ["CalendarBridgeCore"]),
    .executable(name: "CalendarBridge", targets: ["CalendarBridge"]),
  ],
  targets: [
    .target(name: "CalendarBridgeCore"),
    .executableTarget(
      name: "CalendarBridge",
      dependencies: ["CalendarBridgeCore"],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .executableTarget(name: "CalendarBridgeSelfTest", dependencies: ["CalendarBridgeCore"]),
  ]
)
