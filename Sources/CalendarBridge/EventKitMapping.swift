import CalendarBridgeCore
@preconcurrency import EventKit
import Foundation

/// Translation between bridge models and EventKit objects. Nothing here reads
/// or writes the event store; saving and fetching stay in EventKitService.swift.
extension EventKitService {
  func apply(_ draft: ItemDraft, to event: EKEvent) throws {
    let timezone = TimeZone(identifier: draft.timezone ?? CalendarRules.defaultTimeZoneIdentifier)!
    event.title = draft.title
    event.startDate = try CalendarRules.parseDate(
      draft.start!, timeZoneIdentifier: timezone.identifier)
    event.endDate = try CalendarRules.parseDate(draft.end!, timeZoneIdentifier: timezone.identifier)
    event.isAllDay = draft.allDay ?? false
    event.timeZone = timezone
    event.location = draft.location
    event.notes = draft.notes
    event.url = draft.url.flatMap(URL.init(string:))
    event.alarms = try alarms(from: draft.alerts ?? [], timezone: timezone.identifier)
    event.recurrenceRules = try recurrenceRules(
      from: draft.recurrence, timezone: timezone.identifier)
  }

  func apply(_ draft: ItemDraft, to reminder: EKReminder) throws {
    let timezone = TimeZone(identifier: draft.timezone ?? CalendarRules.defaultTimeZoneIdentifier)!
    let due = try CalendarRules.parseDate(draft.due!, timeZoneIdentifier: timezone.identifier)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone
    var components = calendar.dateComponents([.year, .month, .day], from: due)
    if draft.allDay != true {
      let time = calendar.dateComponents([.hour, .minute, .second], from: due)
      components.hour = time.hour
      components.minute = time.minute
      components.second = time.second
    }
    components.timeZone = timezone
    reminder.title = draft.title
    reminder.dueDateComponents = components
    reminder.timeZone = timezone
    reminder.location = draft.location
    reminder.notes = draft.notes
    reminder.url = draft.url.flatMap(URL.init(string:))
    reminder.alarms = try alarms(from: draft.alerts ?? [], timezone: timezone.identifier)
    reminder.recurrenceRules = try recurrenceRules(
      from: draft.recurrence, timezone: timezone.identifier)
  }

  func alarms(from specs: [AlertSpec], timezone: String) throws -> [EKAlarm] {
    try specs.map { spec in
      if let at = spec.at {
        return EKAlarm(absoluteDate: try CalendarRules.parseDate(at, timeZoneIdentifier: timezone))
      }
      if let minutes = spec.minutesBefore { return EKAlarm(relativeOffset: -Double(minutes * 60)) }
      throw BridgeError.invalidRequest("提醒缺少 at 或 minutesBefore。")
    }
  }

  func recurrenceRules(from spec: RecurrenceSpec?, timezone: String) throws
    -> [EKRecurrenceRule]?
  {
    guard let spec else { return nil }
    let frequency: EKRecurrenceFrequency
    switch spec.frequency.lowercased() {
    case "daily": frequency = .daily
    case "weekly": frequency = .weekly
    case "monthly": frequency = .monthly
    default: throw BridgeError.invalidRequest("不支持的循环频率：\(spec.frequency)")
    }
    let weekdayMap: [String: EKWeekday] = [
      "SU": .sunday, "MO": .monday, "TU": .tuesday, "WE": .wednesday,
      "TH": .thursday, "FR": .friday, "SA": .saturday,
    ]
    let weekdays = try spec.daysOfWeek?.map { value -> EKRecurrenceDayOfWeek in
      guard let weekday = weekdayMap[value.uppercased()] else {
        throw BridgeError.invalidRequest("未知星期缩写：\(value)")
      }
      return EKRecurrenceDayOfWeek(weekday)
    }
    let end: EKRecurrenceEnd?
    if let endDate = spec.endDate {
      end = EKRecurrenceEnd(end: try CalendarRules.parseDate(endDate, timeZoneIdentifier: timezone))
    } else if let count = spec.count {
      end = EKRecurrenceEnd(occurrenceCount: count)
    } else {
      end = nil
    }
    return [
      EKRecurrenceRule(
        recurrenceWith: frequency,
        interval: spec.interval ?? 1,
        daysOfTheWeek: weekdays,
        daysOfTheMonth: nil,
        monthsOfTheYear: nil,
        weeksOfTheYear: nil,
        daysOfTheYear: nil,
        setPositions: nil,
        end: end
      )
    ]
  }

  func withResolvedAlerts(_ draft: ItemDraft) throws -> ItemDraft {
    var result = draft
    let timezone = result.timezone ?? CalendarRules.defaultTimeZoneIdentifier
    let reference: Date
    switch result.kind {
    case .event:
      reference = try CalendarRules.parseDate(result.start!, timeZoneIdentifier: timezone)
    case .reminder:
      reference = try CalendarRules.parseDate(result.due!, timeZoneIdentifier: timezone)
    }
    if result.kind == .reminder {
      // A single alert can be represented by Reminders' native Early Reminder
      // field.  This keeps the actual due date visible on iPhone; EventKit's
      // generic reminder alarms otherwise become the displayed date there.
      if result.earlyReminder != nil {
        result.alerts = result.alerts ?? []
        return result
      }
      let resolved = try CalendarRules.resolvedAlerts(
        explicit: result.alerts, referenceDate: reference, timeZoneIdentifier: timezone)
      if resolved.count == 1,
        let spec = try nativeEarlyReminder(for: resolved[0], referenceDate: reference,
          timeZoneIdentifier: timezone)
      {
        result.earlyReminder = spec
        result.alerts = []
      } else {
        result.alerts = resolved
      }
      return result
    }
    result.alerts = try CalendarRules.resolvedAlerts(
      explicit: result.alerts, referenceDate: reference, timeZoneIdentifier: timezone)
    return result
  }

  func nativeEarlyReminder(
    for alert: AlertSpec,
    referenceDate: Date,
    timeZoneIdentifier: String
  ) throws -> EarlyReminderSpec? {
    let alertDate: Date
    if let minutes = alert.minutesBefore {
      guard minutes > 0 else { return nil }
      alertDate = referenceDate.addingTimeInterval(-Double(minutes * 60))
    } else if let at = alert.at {
      alertDate = try CalendarRules.parseDate(at, timeZoneIdentifier: timeZoneIdentifier)
    } else {
      return nil
    }
    let seconds = referenceDate.timeIntervalSince(alertDate)
    guard seconds > 0 else { return nil }
    let minutes = Int((seconds / 60.0).rounded())
    guard minutes > 0, abs(seconds - Double(minutes * 60)) < 0.5 else { return nil }
    return EarlyReminderSpec(unit: 0, count: -minutes)
  }

  func snapshotToDraft(_ snapshot: ItemSnapshot) -> ItemDraft {
    ItemDraft(
      kind: snapshot.summary.kind,
      title: snapshot.summary.title,
      start: snapshot.summary.start,
      end: snapshot.summary.end,
      due: snapshot.summary.due,
      allDay: snapshot.summary.allDay,
      timezone: snapshot.summary.timezone,
      location: snapshot.location,
      notes: snapshot.notes,
      url: snapshot.url,
      alerts: snapshot.summary.alerts,
      earlyReminder: snapshot.summary.earlyReminder,
      recurrence: snapshot.recurrence,
      sourceRef: snapshot.sourceRef
    )
  }

  func summary(_ item: EKCalendarItem) -> ItemSummary {
    if let event = item as? EKEvent { return summary(event: event) }
    return summary(reminder: item as! EKReminder)
  }

  func summary(event: EKEvent) -> ItemSummary {
    ItemSummary(
      id: event.calendarItemIdentifier,
      externalId: event.calendarItemExternalIdentifier,
      kind: .event,
      title: event.title,
      start: CalendarRules.formatDate(
        event.startDate,
        timeZoneIdentifier: event.timeZone?.identifier ?? CalendarRules.defaultTimeZoneIdentifier),
      end: CalendarRules.formatDate(
        event.endDate,
        timeZoneIdentifier: event.timeZone?.identifier ?? CalendarRules.defaultTimeZoneIdentifier),
      allDay: event.isAllDay,
      timezone: event.timeZone?.identifier,
      location: event.location,
      alerts: alertSpecs(event.alarms),
      completed: nil
    )
  }

  func summary(reminder: EKReminder) -> ItemSummary {
    ItemSummary(
      id: reminder.calendarItemIdentifier,
      externalId: reminder.calendarItemExternalIdentifier,
      kind: .reminder,
      title: reminder.title,
      due: dueDate(reminder).map {
        CalendarRules.formatDate(
          $0,
          timeZoneIdentifier: reminder.timeZone?.identifier
            ?? CalendarRules.defaultTimeZoneIdentifier)
      },
      allDay: reminder.dueDateComponents?.hour == nil,
      timezone: reminder.timeZone?.identifier,
      location: reminder.location,
      alerts: alertSpecs(reminder.alarms),
      completed: reminder.isCompleted
    )
  }

  func snapshot(_ item: EKCalendarItem, sourceRef: String? = nil) -> ItemSnapshot {
    ItemSnapshot(
      summary: summary(item),
      calendarIdentifier: item.calendar?.calendarIdentifier,
      location: item.location,
      notes: item.notes,
      url: item.url?.absoluteString,
      recurrence: recurrenceSpec(item.recurrenceRules?.first),
      sourceRef: sourceRef
    )
  }

  func recurrenceSpec(_ rule: EKRecurrenceRule?) -> RecurrenceSpec? {
    guard let rule else { return nil }
    let frequency: String
    switch rule.frequency {
    case .daily: frequency = "daily"
    case .weekly: frequency = "weekly"
    case .monthly: frequency = "monthly"
    default: return nil
    }
    let dayMap: [EKWeekday: String] = [
      .sunday: "SU", .monday: "MO", .tuesday: "TU", .wednesday: "WE", .thursday: "TH",
      .friday: "FR", .saturday: "SA",
    ]
    let days = rule.daysOfTheWeek?.compactMap { dayMap[$0.dayOfTheWeek] }
    let recurrenceEndDate = rule.recurrenceEnd?.endDate
    let occurrenceCount =
      recurrenceEndDate == nil && (rule.recurrenceEnd?.occurrenceCount ?? 0) > 0
      ? rule.recurrenceEnd?.occurrenceCount
      : nil
    return RecurrenceSpec(
      frequency: frequency,
      interval: rule.interval,
      daysOfWeek: days,
      endDate: recurrenceEndDate.map { CalendarRules.formatDate($0) },
      count: occurrenceCount
    )
  }

  func alertSpecs(_ alarms: [EKAlarm]?) -> [AlertSpec] {
    (alarms ?? []).map { alarm in
      if let date = alarm.absoluteDate { return AlertSpec(at: CalendarRules.formatDate(date)) }
      return AlertSpec(minutesBefore: max(0, Int(round(-alarm.relativeOffset / 60))))
    }
  }

  func draftSummary(_ draft: ItemDraft, id: String = "draft") -> ItemSummary {
    ItemSummary(
      id: id,
      kind: draft.kind,
      title: draft.title,
      start: draft.start,
      end: draft.end,
      due: draft.due,
      allDay: draft.allDay ?? false,
      timezone: draft.timezone,
      location: draft.location,
      alerts: draft.alerts ?? [],
      earlyReminder: draft.earlyReminder
    )
  }

  func dueDate(_ reminder: EKReminder) -> Date? {
    guard let components = reminder.dueDateComponents else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone =
      components.timeZone ?? reminder.timeZone ?? TimeZone(
        identifier: CalendarRules.defaultTimeZoneIdentifier)!
    return calendar.date(from: components)
  }

  func authorizationText(_ status: EKAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: "not_determined"
    case .restricted: "restricted"
    case .denied: "denied"
    case .fullAccess: "full_access"
    case .writeOnly: "write_only"
    @unknown default: "unknown"
    }
  }

  func eventSpan(_ scope: String?) -> EKSpan {
    scope?.lowercased() == "future" ? .futureEvents : .thisEvent
  }
}
