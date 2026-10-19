import Foundation

public struct BridgeConfiguration: Codable {
  public var timezone: String?
  public var defaultDurationMinutes: Int?
  public var defaultAlertHour: Int?
  public var defaultAlertMinute: Int?
  public var eventCalendarId: String?
  public var reminderCalendarId: String?
  public static func load() throws -> BridgeConfiguration {
    let path = ProcessInfo.processInfo.environment["CALENDAR_BRIDGE_CONFIG"] ??
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CalendarBridge/config.json").path
    guard FileManager.default.fileExists(atPath: path) else { return BridgeConfiguration() }
    let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    guard TimeZone(identifier: config.timezone ?? "Asia/Singapore") != nil,
      (1...1440).contains(config.defaultDurationMinutes ?? 60),
      (0...23).contains(config.defaultAlertHour ?? 22), (0...59).contains(config.defaultAlertMinute ?? 0) else {
      throw BridgeError.invalidRequest("config.json 默认时区、时长或提醒时间无效。")
    }
    return config
  }
}
