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
    _ = try invoke(command)
    guard try readEarlyReminder(reminderID: reminderID) == spec else {
      throw BridgeError.eventKit("原生提前提醒回读与请求不一致；结果待核查。")
    }
  }

  static func readEarlyReminder(reminderID: String) throws -> EarlyReminderSpec? {
    let response = try invoke(["action": "read_early_reminder", "id": reminderID])
    guard response["status"] as? String == "read", response.keys.contains("earlyReminder") else {
      throw BridgeError.eventKit("原生提前提醒无法可靠回读；未继续写入。")
    }
    if response["earlyReminder"] is NSNull { return nil }
    guard let value = response["earlyReminder"] as? [String: Int], let unit = value["unit"], let count = value["count"] else {
      throw BridgeError.eventKit("原生提前提醒响应格式无效。")
    }
    return EarlyReminderSpec(unit: unit, count: count)
  }

  static func probe() throws {
    let response = try invoke(["action": "probe"])
    guard response["status"] as? String == "available" else {
      throw BridgeError.eventKit("原生提前提醒不可用；未写入提醒事项。")
    }
  }

  private static func invoke(_ command: [String: Any]) throws -> [String: Any] {
    let path = ProcessInfo.processInfo.environment["CALENDAR_BRIDGE_PRIVATE_PATH"] ?? defaultExecutable.path
    let executable = URL(fileURLWithPath: path)
    guard FileManager.default.isExecutableFile(atPath: path) else {
      throw BridgeError.eventKit("缺少原生提前提醒辅助程序；未写入提醒事项。")
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
    let deadline = Date().addingTimeInterval(15)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if process.isRunning {
      process.terminate()
      throw BridgeError.eventKit("原生提醒辅助程序超时，结果待核查；不要重试。")
    }

    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
      let response = (try? JSONSerialization.jsonObject(with: outputData)) as? [String: Any]
      let message = response?["message"] as? String
        ?? String(data: errorData, encoding: .utf8)
        ?? "CalendarBridgePrivate 退出码 \(process.terminationStatus)。"
      throw BridgeError.eventKit(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    guard let response = try JSONSerialization.jsonObject(with: outputData) as? [String: Any],
      let status = response["status"] as? String else {
      throw BridgeError.eventKit("辅助程序响应无效；结果待核查。")
    }
    if status == "error" {
      throw BridgeError.eventKit(response["message"] as? String ?? "CalendarBridgePrivate 写入失败。")
    }
    return response
  }
}
