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
    .executableTarget(name: "CalendarBridgeReliabilityTests", dependencies: ["CalendarBridgeCore"], path: "Tests/ReliabilityTests"),
    .target(
      name: "CalendarBridgeRuntime",
      dependencies: ["CalendarBridgeCore"],
      path: "Sources/CalendarBridge",
      exclude: ["main.swift"],
      sources: ["AuditStore.swift", "EventKitService.swift", "RecoveryAccess.swift", "ReminderKitPrivateService.swift"],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .executableTarget(
      name: "CalendarBridge",
      dependencies: ["CalendarBridgeCore", "CalendarBridgeRuntime"],
      path: "Sources/CalendarBridge",
      exclude: ["AuditStore.swift", "EventKitService.swift", "RecoveryAccess.swift", "ReminderKitPrivateService.swift"],
      sources: ["main.swift"]
    ),
    .executableTarget(name: "CalendarBridgeServiceTests", dependencies: ["CalendarBridgeCore", "CalendarBridgeRuntime"], path: "Tests/ServiceRecoveryTests"),
    .executableTarget(name: "CalendarBridgeSelfTest", dependencies: ["CalendarBridgeCore"]),
  ]
)
