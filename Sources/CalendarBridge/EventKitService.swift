import CalendarBridgeCore
@preconcurrency import EventKit
import Foundation

private final class LockedBox<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: T?

  func set(_ value: T) {
    lock.lock()
    defer { lock.unlock() }
    stored = value
  }

  func get() -> T? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}

final class EventKitService {
  private let store = EKEventStore()
  private let audit: AuditStore
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init() throws {
    audit = try AuditStore()
    encoder.outputFormatting = [.sortedKeys]
  }

  func handle(_ request: BridgeRequest) throws -> BridgeResponse {
    switch request.action {
    case "status": return status(request)
    case "setup": return try setup(request)
    case "event.list": return try listEvents(request)
    case "event.create": return try createOne(request, expectedKind: .event)
    case "event.update": return try updateOne(request, expectedKind: .event)
    case "event.delete": return try deleteOne(request, expectedKind: .event)
    case "reminder.list": return try listReminders(request)
    case "reminder.create": return try createOne(request, expectedKind: .reminder)
    case "reminder.update": return try updateOne(request, expectedKind: .reminder)
    case "reminder.delete": return try deleteOne(request, expectedKind: .reminder)
    case "reminder.complete": return try completeReminder(request)
    case "batch.preview": return try previewBatch(request)
    case "batch.commit": return try commitBatch(request)
    case "batch.rollback": return try rollbackBatch(request)
    default: throw BridgeError.invalidRequest("未知 action：\(request.action)")
    }
  }

  private func status(_ request: BridgeRequest) -> BridgeResponse {
    let events = authorizationText(EKEventStore.authorizationStatus(for: .event))
    let reminders = authorizationText(EKEventStore.authorizationStatus(for: .reminder))
    var details = ["eventAccess": events, "reminderAccess": reminders]
    if EKEventStore.authorizationStatus(for: .event) == .fullAccess,
      let calendar = store.defaultCalendarForNewEvents
    {
      details["eventCalendar"] = calendar.title
      details["eventSource"] = calendar.source.title
      details["eventSourceIsICloud"] = String(isICloud(calendar.source))
    }
    if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
      let calendar = store.defaultCalendarForNewReminders()
    {
      details["reminderList"] = calendar.title
      details["reminderSource"] = calendar.source.title
      details["reminderSourceIsICloud"] = String(isICloud(calendar.source))
    }
    return BridgeResponse(ok: true, status: "ok", requestId: request.requestId, details: details)
  }

  private func setup(_ request: BridgeRequest) throws -> BridgeResponse {
    let eventGranted = try requestAccess(entity: .event)
    let reminderGranted = try requestAccess(entity: .reminder)
    guard eventGranted && reminderGranted else {
      throw BridgeError.permissionDenied("需要在系统设置中授予日历和提醒事项完整访问权限。")
    }
    _ = try defaultEventCalendar()
    _ = try defaultReminderCalendar()
    var response = status(request)
    response.message = "日历与提醒事项权限正常，默认容器均为 iCloud。"
    return response
  }

  private func listEvents(_ request: BridgeRequest) throws -> BridgeResponse {
    try requireAccess(.event)
    let calendar = try defaultEventCalendar()
    let interval = try resolvedRange(request.range)
    let predicate = store.predicateForEvents(
      withStart: interval.start, end: interval.end, calendars: [calendar])
    let items = store.events(matching: predicate).map(summary(event:))
    return BridgeResponse(ok: true, status: "ok", requestId: request.requestId, items: items)
  }

  private func listReminders(_ request: BridgeRequest) throws -> BridgeResponse {
    try requireAccess(.reminder)
    let reminders = try fetchReminders()
    let interval = try request.range.map(resolvedRange)
    let items = reminders.filter { reminder in
      guard let interval, let due = dueDate(reminder) else { return interval == nil }
      return due >= interval.start && due < interval.end
    }.map(summary(reminder:))
    return BridgeResponse(ok: true, status: "ok", requestId: request.requestId, items: items)
  }

  private func createOne(_ request: BridgeRequest, expectedKind: ItemKind) throws -> BridgeResponse
  {
    guard let raw = request.item else { throw BridgeError.invalidRequest("create 缺少 item。") }
    var draft = try CalendarRules.validated(raw)
    guard draft.kind == expectedKind else {
      throw BridgeError.invalidRequest("item.kind 与 action 不一致。")
    }
    draft = try withResolvedAlerts(draft)
    let analysis = try analyze(draft, excluding: nil)
    if request.dryRun == true
      || ((!analysis.conflicts.isEmpty || !analysis.duplicates.isEmpty)
        && request.confirmed != true)
    {
      return BridgeResponse(
        ok: true,
        status: analysis.conflicts.isEmpty && analysis.duplicates.isEmpty
          ? "preview" : "needs_confirmation",
        requestId: request.requestId,
        items: [draftSummary(draft)],
        conflicts: analysis.conflicts,
        duplicates: analysis.duplicates
      )
    }
    let batchId = request.batchId ?? UUID().uuidString.lowercased()
    try audit.beginBatch(id: batchId, action: request.action)
    let created = try create(draft, batchId: batchId)
    return BridgeResponse(
      ok: true, status: "committed", requestId: request.requestId, batchId: batchId,
      items: [created])
  }

  private func updateOne(_ request: BridgeRequest, expectedKind: ItemKind) throws -> BridgeResponse
  {
    guard let selector = request.selector, let raw = request.item else {
      throw BridgeError.invalidRequest("update 需要 selector 和 item。")
    }
    var draft = try CalendarRules.validated(raw)
    guard draft.kind == expectedKind else {
      throw BridgeError.invalidRequest("item.kind 与 action 不一致。")
    }
    draft = try withResolvedAlerts(draft)
    let existing = try findItem(selector, kind: expectedKind)
    let analysis = try analyze(draft, excluding: existing.calendarItemIdentifier)
    if request.dryRun == true {
      return BridgeResponse(
        ok: true,
        status: analysis.conflicts.isEmpty && analysis.duplicates.isEmpty
          ? "preview" : "needs_confirmation",
        requestId: request.requestId,
        items: [draftSummary(draft)],
        conflicts: analysis.conflicts,
        duplicates: analysis.duplicates
      )
    }
    guard request.confirmed == true else { throw BridgeError.confirmationRequired("修改事项前必须确认。") }
    let batchId = request.batchId ?? UUID().uuidString.lowercased()
    try audit.beginBatch(id: batchId, action: request.action)
    let result = try update(existing, with: draft, batchId: batchId, scope: request.scope)
    return BridgeResponse(
      ok: true, status: "committed", requestId: request.requestId, batchId: batchId, items: [result]
    )
  }

  private func deleteOne(_ request: BridgeRequest, expectedKind: ItemKind) throws -> BridgeResponse
  {
    guard request.confirmed == true else { throw BridgeError.confirmationRequired("删除事项前必须确认。") }
    guard let selector = request.selector else {
      throw BridgeError.invalidRequest("delete 缺少 selector。")
    }
    let existing = try findItem(selector, kind: expectedKind)
    let batchId = request.batchId ?? UUID().uuidString.lowercased()
    try audit.beginBatch(id: batchId, action: request.action)
    let before = snapshot(existing)
    try remove(existing, scope: request.scope)
    try audit.record(
      batchId: batchId,
      action: "delete",
      entityType: expectedKind,
      calendarItemId: existing.calendarItemIdentifier,
      externalId: existing.calendarItemExternalIdentifier,
      before: before,
      after: nil
    )
    return BridgeResponse(
      ok: true, status: "committed", requestId: request.requestId, batchId: batchId,
      items: [before.summary])
  }

  private func completeReminder(_ request: BridgeRequest) throws -> BridgeResponse {
    guard request.confirmed == true else { throw BridgeError.confirmationRequired("完成待办前必须确认。") }
    guard let selector = request.selector else {
      throw BridgeError.invalidRequest("complete 缺少 selector。")
    }
    guard let reminder = try findItem(selector, kind: .reminder) as? EKReminder else {
      throw BridgeError.notFound("找不到待办。")
    }
    let batchId = request.batchId ?? UUID().uuidString.lowercased()
    try audit.beginBatch(id: batchId, action: request.action)
    let before = snapshot(reminder)
    reminder.isCompleted = true
    reminder.completionDate = Date()
    do { try store.save(reminder, commit: true) } catch {
      throw BridgeError.eventKit(error.localizedDescription)
    }
    let after = snapshot(reminder)
    try audit.record(
      batchId: batchId, action: "complete", entityType: .reminder,
      calendarItemId: reminder.calendarItemIdentifier,
      externalId: reminder.calendarItemExternalIdentifier, before: before, after: after)
    return BridgeResponse(
      ok: true, status: "committed", requestId: request.requestId, batchId: batchId,
      items: [after.summary])
  }

  private func previewBatch(_ request: BridgeRequest) throws -> BridgeResponse {
    guard let rawItems = request.items, !rawItems.isEmpty else {
      throw BridgeError.invalidRequest("batch.preview 需要非空 items。")
    }
    var drafts: [ItemDraft] = []
    var conflicts: [ItemSummary] = []
    var duplicates: [ItemSummary] = []
    for raw in rawItems {
      let draft = try withResolvedAlerts(CalendarRules.validated(raw))
      drafts.append(draft)
      let analysis = try analyze(draft, excluding: nil)
      conflicts.append(contentsOf: analysis.conflicts)
      duplicates.append(contentsOf: analysis.duplicates)
    }
    for left in drafts.indices {
      for right in drafts.indices where right > left {
        if areDuplicate(drafts[left], drafts[right]) {
          duplicates.append(draftSummary(drafts[right], id: "draft-\(right + 1)"))
        }
        if overlap(drafts[left], drafts[right]) {
          conflicts.append(draftSummary(drafts[right], id: "draft-\(right + 1)"))
        }
      }
    }
    return BridgeResponse(
      ok: true,
      status: conflicts.isEmpty && duplicates.isEmpty ? "preview" : "needs_confirmation",
      requestId: request.requestId,
      batchId: request.batchId ?? UUID().uuidString.lowercased(),
      items: drafts.enumerated().map { draftSummary($0.element, id: "draft-\($0.offset + 1)") },
      conflicts: unique(conflicts),
      duplicates: unique(duplicates)
    )
  }

  private func commitBatch(_ request: BridgeRequest) throws -> BridgeResponse {
    guard request.confirmed == true else { throw BridgeError.confirmationRequired("批量写入前必须确认预览。") }
    guard let rawItems = request.items, !rawItems.isEmpty else {
      throw BridgeError.invalidRequest("batch.commit 需要非空 items。")
    }
    let batchId = request.batchId ?? UUID().uuidString.lowercased()
    try audit.beginBatch(id: batchId, action: request.action)
    var created: [ItemSummary] = []
    do {
      for raw in rawItems {
        let draft = try withResolvedAlerts(CalendarRules.validated(raw))
        created.append(try create(draft, batchId: batchId))
      }
    } catch {
      _ = try? rollback(batchId)
      throw error
    }
    return BridgeResponse(
      ok: true, status: "committed", requestId: request.requestId, batchId: batchId, items: created)
  }

  private func rollbackBatch(_ request: BridgeRequest) throws -> BridgeResponse {
    guard request.confirmed == true else { throw BridgeError.confirmationRequired("回滚批次前必须确认。") }
    guard let batchId = request.batchId else {
      throw BridgeError.invalidRequest("batch.rollback 缺少 batchId。")
    }
    let restored = try rollback(batchId)
    return BridgeResponse(
      ok: true, status: "rolled_back", requestId: request.requestId, batchId: batchId,
      items: restored)
  }

  private func rollback(_ batchId: String) throws -> [ItemSummary] {
    let operations = try audit.operations(for: batchId)
    guard !operations.isEmpty else { throw BridgeError.notFound("找不到可回滚批次：\(batchId)") }
    var results: [ItemSummary] = []
    for operation in operations {
      let before = try decodeSnapshot(operation.beforeJSON)
      let after = try decodeSnapshot(operation.afterJSON)
      let kind =
        ItemKind(rawValue: operation.entityType) ?? before?.summary.kind ?? after?.summary.kind
      guard let kind else { continue }
      switch operation.action {
      case "create":
        if let item = try findRecordedItem(
          id: operation.calendarItemId, snapshot: after, kind: kind)
        {
          try remove(item, scope: "future")
          results.append(summary(item))
        }
      case "update", "complete":
        guard let before else { continue }
        if let item = try findRecordedItem(
          id: operation.calendarItemId, snapshot: after, kind: kind)
        {
          results.append(try restore(before, onto: item))
        } else {
          results.append(try create(snapshotToDraft(before), batchId: nil))
        }
      case "delete":
        if let before { results.append(try create(snapshotToDraft(before), batchId: nil)) }
      default: continue
      }
    }
    try audit.markRolledBack(batchId)
    return results
  }

  private func create(_ draft: ItemDraft, batchId: String?) throws -> ItemSummary {
    switch draft.kind {
    case .event:
      try requireAccess(.event)
      let event = EKEvent(eventStore: store)
      event.calendar = try defaultEventCalendar()
      try apply(draft, to: event)
      do { try store.save(event, span: .thisEvent, commit: true) } catch {
        throw BridgeError.eventKit(error.localizedDescription)
      }
      let after = snapshot(event, sourceRef: draft.sourceRef)
      if let batchId {
        try audit.record(
          batchId: batchId, action: "create", entityType: .event,
          calendarItemId: event.calendarItemIdentifier,
          externalId: event.calendarItemExternalIdentifier, before: nil, after: after)
      }
      return try verifiedSummary(id: event.calendarItemIdentifier, fallback: after.summary)
    case .reminder:
      try requireAccess(.reminder)
      let reminder = EKReminder(eventStore: store)
      reminder.calendar = try defaultReminderCalendar()
      try apply(draft, to: reminder)
      do { try store.save(reminder, commit: true) } catch {
        throw BridgeError.eventKit(error.localizedDescription)
      }
      do {
        try ReminderKitPrivateService.setEarlyReminder(
          reminderID: reminder.calendarItemIdentifier, spec: draft.earlyReminder)
      } catch {
        try? store.remove(reminder, commit: true)
        throw error
      }
      var after = snapshot(reminder, sourceRef: draft.sourceRef)
      after.summary.earlyReminder = draft.earlyReminder
      if let batchId {
        try audit.record(
          batchId: batchId, action: "create", entityType: .reminder,
          calendarItemId: reminder.calendarItemIdentifier,
          externalId: reminder.calendarItemExternalIdentifier, before: nil, after: after)
      }
      return try verifiedSummary(id: reminder.calendarItemIdentifier, fallback: after.summary)
    }
  }

  private func update(
    _ existing: EKCalendarItem, with draft: ItemDraft, batchId: String, scope: String?
  ) throws -> ItemSummary {
    let before = snapshot(existing)
    if let event = existing as? EKEvent {
      try apply(draft, to: event)
      do { try store.save(event, span: eventSpan(scope), commit: true) } catch {
        throw BridgeError.eventKit(error.localizedDescription)
      }
    } else if let reminder = existing as? EKReminder {
      try apply(draft, to: reminder)
      do { try store.save(reminder, commit: true) } catch {
        throw BridgeError.eventKit(error.localizedDescription)
      }
      try ReminderKitPrivateService.setEarlyReminder(
        reminderID: reminder.calendarItemIdentifier, spec: draft.earlyReminder)
    }
    var after = snapshot(existing, sourceRef: draft.sourceRef)
    if draft.kind == .reminder {
      after.summary.earlyReminder = draft.earlyReminder
    }
    try audit.record(
      batchId: batchId, action: "update", entityType: draft.kind,
      calendarItemId: existing.calendarItemIdentifier,
      externalId: existing.calendarItemExternalIdentifier, before: before, after: after)
    return try verifiedSummary(id: existing.calendarItemIdentifier, fallback: after.summary)
  }

  private func apply(_ draft: ItemDraft, to event: EKEvent) throws {
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

  private func apply(_ draft: ItemDraft, to reminder: EKReminder) throws {
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

  private func alarms(from specs: [AlertSpec], timezone: String) throws -> [EKAlarm] {
    try specs.map { spec in
      if let at = spec.at {
        return EKAlarm(absoluteDate: try CalendarRules.parseDate(at, timeZoneIdentifier: timezone))
      }
      if let minutes = spec.minutesBefore { return EKAlarm(relativeOffset: -Double(minutes * 60)) }
      throw BridgeError.invalidRequest("提醒缺少 at 或 minutesBefore。")
    }
  }

  private func recurrenceRules(from spec: RecurrenceSpec?, timezone: String) throws
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

  private func withResolvedAlerts(_ draft: ItemDraft) throws -> ItemDraft {
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

  private func nativeEarlyReminder(
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

  private func analyze(_ draft: ItemDraft, excluding id: String?) throws -> (
    conflicts: [ItemSummary], duplicates: [ItemSummary]
  ) {
    switch draft.kind {
    case .event:
      try requireAccess(.event)
      let start = try CalendarRules.parseDate(draft.start!, timeZoneIdentifier: draft.timezone!)
      let end = try CalendarRules.parseDate(draft.end!, timeZoneIdentifier: draft.timezone!)
      let calendar = try defaultEventCalendar()
      let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
      let existing = store.events(matching: predicate).filter { $0.calendarItemIdentifier != id }
      let conflicts = existing.map(summary(event:))
      let duplicates = existing.filter {
        CalendarRules.normalizedTitle($0.title) == CalendarRules.normalizedTitle(draft.title)
          && abs($0.startDate.timeIntervalSince(start)) <= 900
      }.map(summary(event:))
      return (conflicts, duplicates)
    case .reminder:
      try requireAccess(.reminder)
      let due = try CalendarRules.parseDate(draft.due!, timeZoneIdentifier: draft.timezone!)
      let reminders = try fetchReminders().filter { $0.calendarItemIdentifier != id }
      let duplicates = reminders.filter {
        CalendarRules.normalizedTitle($0.title) == CalendarRules.normalizedTitle(draft.title)
          && self.dueDate($0).map { abs($0.timeIntervalSince(due)) <= 86_400 } == true
      }.map(summary(reminder:))
      return ([], duplicates)
    }
  }

  private func areDuplicate(_ left: ItemDraft, _ right: ItemDraft) -> Bool {
    guard left.kind == right.kind,
      CalendarRules.normalizedTitle(left.title) == CalendarRules.normalizedTitle(right.title)
    else { return false }
    let leftDate = left.kind == .event ? left.start : left.due
    let rightDate = right.kind == .event ? right.start : right.due
    guard let l = leftDate, let r = rightDate,
      let ld = try? CalendarRules.parseDate(l, timeZoneIdentifier: left.timezone!),
      let rd = try? CalendarRules.parseDate(r, timeZoneIdentifier: right.timezone!)
    else { return false }
    return abs(ld.timeIntervalSince(rd)) <= (left.kind == .event ? 900 : 86_400)
  }

  private func overlap(_ left: ItemDraft, _ right: ItemDraft) -> Bool {
    guard left.kind == .event, right.kind == .event,
      let ls = try? CalendarRules.parseDate(left.start!, timeZoneIdentifier: left.timezone!),
      let le = try? CalendarRules.parseDate(left.end!, timeZoneIdentifier: left.timezone!),
      let rs = try? CalendarRules.parseDate(right.start!, timeZoneIdentifier: right.timezone!),
      let re = try? CalendarRules.parseDate(right.end!, timeZoneIdentifier: right.timezone!)
    else { return false }
    return ls < re && rs < le
  }

  private func findItem(_ selector: ItemSelector, kind: ItemKind) throws -> EKCalendarItem {
    if let id = selector.id, let item = store.calendarItem(withIdentifier: id) {
      guard (kind == .event && item is EKEvent) || (kind == .reminder && item is EKReminder) else {
        throw BridgeError.notFound("标识对应的事项类型不匹配。")
      }
      return item
    }
    guard let title = selector.title else {
      throw BridgeError.invalidRequest("selector 必须包含 id，或包含 title 与 near。")
    }
    let near = try selector.near.map { try CalendarRules.parseDate($0) }
    let candidates: [EKCalendarItem]
    if kind == .event {
      let center = near ?? Date()
      let predicate = store.predicateForEvents(
        withStart: center.addingTimeInterval(-86_400), end: center.addingTimeInterval(86_400),
        calendars: [try defaultEventCalendar()])
      candidates = store.events(matching: predicate)
    } else {
      candidates = try fetchReminders()
    }
    let matches = candidates.filter { item in
      guard CalendarRules.normalizedTitle(item.title) == CalendarRules.normalizedTitle(title) else {
        return false
      }
      guard let near else { return true }
      if let event = item as? EKEvent {
        return abs(event.startDate.timeIntervalSince(near)) <= 86_400
      }
      if let reminder = item as? EKReminder, let due = dueDate(reminder) {
        return abs(due.timeIntervalSince(near)) <= 86_400
      }
      return false
    }
    guard matches.count == 1, let match = matches.first else {
      if matches.isEmpty { throw BridgeError.notFound("找不到匹配事项。") }
      throw BridgeError.confirmationRequired("找到多个匹配事项，请使用明确 id。")
    }
    return match
  }

  private func findRecordedItem(id: String?, snapshot: ItemSnapshot?, kind: ItemKind) throws
    -> EKCalendarItem?
  {
    if let id, let item = store.calendarItem(withIdentifier: id) { return item }
    guard let snapshot else { return nil }
    return try? findItem(
      ItemSelector(
        title: snapshot.summary.title, near: snapshot.summary.start ?? snapshot.summary.due),
      kind: kind)
  }

  private func remove(_ item: EKCalendarItem, scope: String?) throws {
    do {
      if let event = item as? EKEvent {
        try store.remove(event, span: eventSpan(scope), commit: true)
      } else if let reminder = item as? EKReminder {
        try store.remove(reminder, commit: true)
      }
    } catch { throw BridgeError.eventKit(error.localizedDescription) }
  }

  private func restore(_ snapshot: ItemSnapshot, onto item: EKCalendarItem) throws -> ItemSummary {
    let draft = snapshotToDraft(snapshot)
    if let event = item as? EKEvent {
      try apply(draft, to: event)
      do { try store.save(event, span: .thisEvent, commit: true) } catch {
        throw BridgeError.eventKit(error.localizedDescription)
      }
    } else if let reminder = item as? EKReminder {
      try apply(draft, to: reminder)
      reminder.isCompleted = snapshot.summary.completed ?? false
      do { try store.save(reminder, commit: true) } catch {
        throw BridgeError.eventKit(error.localizedDescription)
      }
      try ReminderKitPrivateService.setEarlyReminder(
        reminderID: reminder.calendarItemIdentifier, spec: draft.earlyReminder)
    }
    return summary(item)
  }

  private func snapshotToDraft(_ snapshot: ItemSnapshot) -> ItemDraft {
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

  private func summary(_ item: EKCalendarItem) -> ItemSummary {
    if let event = item as? EKEvent { return summary(event: event) }
    return summary(reminder: item as! EKReminder)
  }

  private func summary(event: EKEvent) -> ItemSummary {
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

  private func summary(reminder: EKReminder) -> ItemSummary {
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

  private func snapshot(_ item: EKCalendarItem, sourceRef: String? = nil) -> ItemSnapshot {
    ItemSnapshot(
      summary: summary(item),
      location: item.location,
      notes: item.notes,
      url: item.url?.absoluteString,
      recurrence: recurrenceSpec(item.recurrenceRules?.first),
      sourceRef: sourceRef
    )
  }

  private func recurrenceSpec(_ rule: EKRecurrenceRule?) -> RecurrenceSpec? {
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

  private func alertSpecs(_ alarms: [EKAlarm]?) -> [AlertSpec] {
    (alarms ?? []).map { alarm in
      if let date = alarm.absoluteDate { return AlertSpec(at: CalendarRules.formatDate(date)) }
      return AlertSpec(minutesBefore: max(0, Int(round(-alarm.relativeOffset / 60))))
    }
  }

  private func draftSummary(_ draft: ItemDraft, id: String = "draft") -> ItemSummary {
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

  private func verifiedSummary(id: String, fallback: ItemSummary) throws -> ItemSummary {
    store.refreshSourcesIfNecessary()
    guard let item = store.calendarItem(withIdentifier: id) else { return fallback }
    let actual = summary(item)
    if fallback.kind == .reminder, fallback.earlyReminder != nil {
      var adjusted = actual
      adjusted.earlyReminder = fallback.earlyReminder
      return adjusted
    }
    if actual.alerts.count < fallback.alerts.count {
      var adjusted = actual
      adjusted.alerts = actual.alerts
      return adjusted
    }
    return actual
  }

  private func unique(_ items: [ItemSummary]) -> [ItemSummary] {
    var ids = Set<String>()
    return items.filter { ids.insert($0.id).inserted }
  }

  private func dueDate(_ reminder: EKReminder) -> Date? {
    guard let components = reminder.dueDateComponents else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone =
      components.timeZone ?? reminder.timeZone ?? TimeZone(
        identifier: CalendarRules.defaultTimeZoneIdentifier)!
    return calendar.date(from: components)
  }

  private func resolvedRange(_ range: DateRange?) throws -> (start: Date, end: Date) {
    if let range {
      let start = try CalendarRules.parseDate(range.start)
      let end = try CalendarRules.parseDate(range.end)
      guard end > start else { throw BridgeError.invalidRequest("range.end 必须晚于 range.start。") }
      return (start, end)
    }
    let now = Date()
    return (now.addingTimeInterval(-30 * 86_400), now.addingTimeInterval(365 * 86_400))
  }

  private func fetchReminders() throws -> [EKReminder] {
    let calendar = try defaultReminderCalendar()
    let semaphore = DispatchSemaphore(value: 0)
    let box = LockedBox<[EKReminder]>()
    store.fetchReminders(matching: store.predicateForReminders(in: [calendar])) { reminders in
      box.set(reminders ?? [])
      semaphore.signal()
    }
    semaphore.wait()
    return box.get() ?? []
  }

  private func requestAccess(entity: EKEntityType) throws -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    let box = LockedBox<Result<Bool, Error>>()
    let completion: @Sendable (Bool, Error?) -> Void = { granted, error in
      if let error { box.set(.failure(error)) } else { box.set(.success(granted)) }
      semaphore.signal()
    }
    if entity == .event {
      store.requestFullAccessToEvents(completion: completion)
    } else {
      store.requestFullAccessToReminders(completion: completion)
    }
    semaphore.wait()
    switch box.get() {
    case .success(let granted): return granted
    case .failure(let error): throw BridgeError.permissionDenied(error.localizedDescription)
    case nil: throw BridgeError.permissionDenied("系统未返回授权结果。")
    }
  }

  private func requireAccess(_ entity: EKEntityType) throws {
    guard EKEventStore.authorizationStatus(for: entity) == .fullAccess else {
      throw BridgeError.permissionDenied("请先执行 setup 并授予完整访问权限。")
    }
  }

  private func defaultEventCalendar() throws -> EKCalendar {
    try requireAccess(.event)
    guard let calendar = store.defaultCalendarForNewEvents else {
      throw BridgeError.eventKit("没有默认日历。")
    }
    guard isICloud(calendar.source) else {
      throw BridgeError.iCloudRequired(
        "默认日历“\(calendar.title)”来自“\(calendar.source.title)”，不是 iCloud。")
    }
    return calendar
  }

  private func defaultReminderCalendar() throws -> EKCalendar {
    try requireAccess(.reminder)
    guard let calendar = store.defaultCalendarForNewReminders() else {
      throw BridgeError.eventKit("没有默认提醒事项列表。")
    }
    guard isICloud(calendar.source) else {
      throw BridgeError.iCloudRequired(
        "默认提醒列表“\(calendar.title)”来自“\(calendar.source.title)”，不是 iCloud。")
    }
    return calendar
  }

  private func isICloud(_ source: EKSource) -> Bool {
    source.sourceType == .calDAV && source.title.lowercased().contains("icloud")
  }

  private func authorizationText(_ status: EKAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: "not_determined"
    case .restricted: "restricted"
    case .denied: "denied"
    case .fullAccess: "full_access"
    case .writeOnly: "write_only"
    @unknown default: "unknown"
    }
  }

  private func eventSpan(_ scope: String?) -> EKSpan {
    scope?.lowercased() == "future" ? .futureEvents : .thisEvent
  }

  private func decodeSnapshot(_ json: String?) throws -> ItemSnapshot? {
    guard let json, let data = json.data(using: .utf8) else { return nil }
    return try decoder.decode(ItemSnapshot.self, from: data)
  }
}
