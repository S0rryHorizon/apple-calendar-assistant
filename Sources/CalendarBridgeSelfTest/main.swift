import CalendarBridgeCore
import Foundation

private var failures: [String] = []

private func check(_ condition: @autoclosure () throws -> Bool, _ name: String) {
  do {
    if try !condition() { failures.append(name) }
  } catch {
    failures.append("\(name): \(error)")
  }
}

private let singapore = "Asia/Singapore"

do {
  let event = try CalendarRules.validated(
    ItemDraft(kind: .event, title: "上课", start: "2026-09-01T09:00:00+08:00"))
  let eventStart = try CalendarRules.parseDate(event.start!, timeZoneIdentifier: singapore)
  let eventEnd = try CalendarRules.parseDate(event.end!, timeZoneIdentifier: singapore)
  check(eventEnd.timeIntervalSince(eventStart) == 3_600, "事件默认一小时")

  let allDay = try CalendarRules.validated(
    ItemDraft(kind: .event, title: "校庆", start: "2026-09-01", allDay: true))
  let allDayStart = try CalendarRules.parseDate(allDay.start!, timeZoneIdentifier: singapore)
  let allDayEnd = try CalendarRules.parseDate(allDay.end!, timeZoneIdentifier: singapore)
  check(allDayEnd.timeIntervalSince(allDayStart) == 86_400, "全天事件默认一天")

  var missingDueFailed = false
  do { _ = try CalendarRules.validated(ItemDraft(kind: .reminder, title: "交报告")) } catch {
    missingDueFailed = true
  }
  check(missingDueFailed, "待办缺少日期时拒绝")

  let reference = try CalendarRules.parseDate("2026-09-03T09:00:00+08:00")
  let earlyNow = try CalendarRules.parseDate("2026-09-01T12:00:00+08:00")
  let defaultAlerts = try CalendarRules.resolvedAlerts(
    explicit: nil, referenceDate: reference, now: earlyNow)
  check(defaultAlerts == [AlertSpec(at: "2026-09-02T22:00:00+08:00")], "前一自然日 22 点提醒")

  let sameDayNow = try CalendarRules.parseDate("2026-09-03T06:00:00+08:00")
  let oneHour = try CalendarRules.resolvedAlerts(
    explicit: nil, referenceDate: reference, now: sameDayNow)
  check(oneHour == [AlertSpec(at: "2026-09-03T08:00:00+08:00")], "错过默认后提前一小时")

  let nearNow = try CalendarRules.parseDate("2026-09-03T08:30:00+08:00")
  let fifteenMinutes = try CalendarRules.resolvedAlerts(
    explicit: nil, referenceDate: reference, now: nearNow)
  check(fifteenMinutes == [AlertSpec(at: "2026-09-03T08:45:00+08:00")], "错过默认后提前十五分钟")

  let explicit = [AlertSpec(minutesBefore: 60)]
  check(
    try CalendarRules.resolvedAlerts(explicit: explicit, referenceDate: reference) == explicit,
    "显式提醒替换默认")
  check(
    try CalendarRules.resolvedAlerts(explicit: [], referenceDate: reference).isEmpty, "空显式提醒删除全部")

  let locatedSummary = ItemSummary(
    id: "location-test",
    kind: .event,
    title: "地点回读测试",
    location: "Room 201")
  let encodedSummary = try JSONEncoder().encode(locatedSummary)
  let encodedObject = try JSONSerialization.jsonObject(with: encodedSummary) as? [String: Any]
  check(encodedObject?["location"] as? String == "Room 201", "地点包含在摘要 JSON 中")
} catch {
  failures.append("测试准备失败：\(error)")
}

if failures.isEmpty {
  print("CalendarBridgeCore: 9 checks passed")
} else {
  for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
  exit(1)
}
