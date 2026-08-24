import CalendarBridgeCore
import Foundation

/// Minimal bridge to the one Reminders field that EventKit cannot represent:
/// the native Early Reminder (due-date delta alert).  The helper is kept
/// outside the signed CalendarBridge.app bundle so updating it does not change
/// the EventKit app's identity or its macOS permission grant.
enum ReminderKitPrivateService {
  static var defaultExecutable: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Applications/CalendarBridgePrivate")
  }

  static func setEarlyReminder(
    reminderID: String,
    spec: EarlyReminderSpec?
  ) throws {
    let path = ProcessInfo.processInfo.environment["CALENDAR_BRIDGE_PRIVATE_PATH"]
      .flatMap { $0.isEmpty ? nil : $0 }
    let executable = URL(fileURLWithPath: path ?? defaultExecutable.path)
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw BridgeError.eventKit(
        "缺少 CalendarBridgePrivate；请重新运行项目的 scripts/install.sh。")
    }

    var command: [String: Any] = [
      "action": "set_early_reminder",
      "id": reminderID,
    ]
    if let spec {
      command["unit"] = spec.unit
      command["count"] = spec.count
    } else {
      command["clear"] = true
    }
    let input = try JSONSerialization.data(withJSONObject: command, options: [])

    let process = Process()
    process.executableURL = executable
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    stdin.fileHandleForWriting.write(input)
    stdin.fileHandleForWriting.closeFile()
    process.waitUntilExit()

    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
      let response = (try? JSONSerialization.jsonObject(with: outputData)) as? [String: Any]
      let message = response?["message"] as? String
        ?? String(data: errorData, encoding: .utf8)
        ?? "CalendarBridgePrivate 退出码 \(process.terminationStatus)。"
      throw BridgeError.eventKit(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if let response = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any],
      let status = response["status"] as? String, status == "error"
    {
      throw BridgeError.eventKit(response["message"] as? String ?? "CalendarBridgePrivate 写入失败。")
    }
  }
}
