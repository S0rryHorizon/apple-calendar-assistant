import Foundation

public enum CalendarRules {
  public static let defaultTimeZoneIdentifier = "Asia/Singapore"

  public static func parseDate(
    _ value: String, timeZoneIdentifier: String = defaultTimeZoneIdentifier
  ) throws -> Date {
    let isoWithFractional = ISO8601DateFormatter()
    isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = isoWithFractional.date(from: value) { return date }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: value) { return date }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
    for format in [
      "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm",
      "yyyy-MM-dd",
    ] {
      formatter.dateFormat = format
      if let date = formatter.date(from: value) { return date }
    }
    throw BridgeError.invalidRequest("无法解析日期：\(value)。请使用 ISO 8601 或 yyyy-MM-dd HH:mm。")
  }

  public static func formatDate(
    _ date: Date, timeZoneIdentifier: String = defaultTimeZoneIdentifier
  ) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
    return formatter.string(from: date)
  }

  public static func validated(_ draft: ItemDraft) throws -> ItemDraft {
    var item = draft
    item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !item.title.isEmpty else {
      throw BridgeError.invalidRequest("事项标题不能为空。")
    }
    let timezone = item.timezone ?? defaultTimeZoneIdentifier
    guard TimeZone(identifier: timezone) != nil else {
      throw BridgeError.invalidRequest("未知时区：\(timezone)")
    }
    item.timezone = timezone

    switch item.kind {
    case .event:
      if item.earlyReminder != nil {
        throw BridgeError.invalidRequest("earlyReminder 只能用于提醒事项。")
      }
      guard let startString = item.start else {
        throw BridgeError.invalidRequest("事件缺少开始日期或时间。")
      }
      let start = try parseDate(startString, timeZoneIdentifier: timezone)
      if let endString = item.end {
        let end = try parseDate(endString, timeZoneIdentifier: timezone)
        guard end > start else {
          throw BridgeError.invalidRequest("事件结束时间必须晚于开始时间。")
        }
      } else {
        let seconds: TimeInterval = item.allDay == true ? 86_400 : 3_600
        item.end = formatDate(start.addingTimeInterval(seconds), timeZoneIdentifier: timezone)
      }
    case .reminder:
      guard let dueString = item.due else {
        throw BridgeError.invalidRequest("待办缺少到期日期；应先向用户追问。")
      }
      _ = try parseDate(dueString, timeZoneIdentifier: timezone)
      if let early = item.earlyReminder {
        guard (0...4).contains(early.unit) else {
          throw BridgeError.invalidRequest("earlyReminder.unit 必须为 0（分钟）到 4（月份）。")
        }
        guard early.count != 0 else {
          throw BridgeError.invalidRequest("earlyReminder.count 不能为 0。")
        }
      }
    }
    if let recurrence = item.recurrence {
      let frequencies = ["daily", "weekly", "monthly"]
      guard frequencies.contains(recurrence.frequency.lowercased()) else {
        throw BridgeError.invalidRequest("第一版仅支持 daily、weekly、monthly 循环。")
      }
      if let interval = recurrence.interval, interval < 1 {
        throw BridgeError.invalidRequest("循环间隔必须至少为 1。")
      }
      if recurrence.endDate != nil && recurrence.count != nil {
        throw BridgeError.invalidRequest("循环只能指定 endDate 或 count 其中之一。")
      }
    }
    return item
  }

  public static func resolvedAlerts(
    explicit: [AlertSpec]?,
    referenceDate: Date,
    now: Date = Date(),
    timeZoneIdentifier: String = defaultTimeZoneIdentifier
  ) throws -> [AlertSpec] {
    if let explicit {
      for alert in explicit {
        let hasAbsolute = alert.at != nil
        let hasRelative = alert.minutesBefore != nil
        guard hasAbsolute != hasRelative else {
          throw BridgeError.invalidRequest("每个提醒必须且只能包含 at 或 minutesBefore。")
        }
        if let at = alert.at { _ = try parseDate(at, timeZoneIdentifier: timeZoneIdentifier) }
        if let minutes = alert.minutesBefore, minutes < 0 {
          throw BridgeError.invalidRequest("minutesBefore 不能为负数。")
        }
      }
      return explicit
    }

    guard referenceDate > now else {
      throw BridgeError.invalidRequest("事项时间已经过去。")
    }
    let timezone = TimeZone(identifier: timeZoneIdentifier) ?? .current
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone
    let referenceDay = calendar.startOfDay(for: referenceDate)
    guard let previousDay = calendar.date(byAdding: .day, value: -1, to: referenceDay),
      let defaultAlert = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: previousDay)
    else {
      throw BridgeError.invalidRequest("无法计算默认提醒时间。")
    }
    if defaultAlert > now {
      return [AlertSpec(at: formatDate(defaultAlert, timeZoneIdentifier: timeZoneIdentifier))]
    }

    let remaining = referenceDate.timeIntervalSince(now)
    let fallback: Date
    if remaining >= 3_600 {
      fallback = referenceDate.addingTimeInterval(-3_600)
    } else if remaining >= 900 {
      fallback = referenceDate.addingTimeInterval(-900)
    } else {
      fallback = now
    }
    return [AlertSpec(at: formatDate(fallback, timeZoneIdentifier: timeZoneIdentifier))]
  }

  public static func normalizedTitle(_ title: String) -> String {
    title.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_CN")
    )
    .split(whereSeparator: { $0.isWhitespace })
    .joined()
  }
}
