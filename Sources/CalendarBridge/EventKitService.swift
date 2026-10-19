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

package final class EventKitService: RecoveryBackend {
  private lazy var store = EKEventStore()
  private let journal: OperationJournal
  private let audit: AuditStore
  private let injectedRecovery: (any RecoveryBackend)?
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  private var recovery: any RecoveryBackend { injectedRecovery ?? self }

  package init() throws {
    _ = try BridgeConfiguration.load()
    journal = try OperationJournal(directory: AuditStore.baseDirectory.appendingPathComponent("journal-v2"))
    audit = try AuditStore()
    injectedRecovery = nil
    encoder.outputFormatting = [.sortedKeys]
  }

  package init(journal: OperationJournal, audit: AuditStore, recovery: any RecoveryBackend) {
    self.journal = journal
    self.audit = audit
    injectedRecovery = recovery
    encoder.outputFormatting = [.sortedKeys]
  }

  package func handle(_ request: BridgeRequest) throws -> BridgeResponse {
    if request.dryRun == true && ["batch.commit", "batch.rollback"].contains(request.action) {
      throw BridgeError.invalidRequest("请使用 batch.preview；回滚须单独确认。")
    }
    if request.action == "operation.reconcile" { return try reconcile(request) }
    if request.action == "operation.status" {
      guard let id = request.batchId else { throw BridgeError.notFound("没有此操作记录。") }
      if let rollback = try recordedRollbackResponse(for: id) { return rollback }
      guard let record = try journal.read("operation:" + id, as: OperationRecord.self) else {
        throw BridgeError.notFound("没有此操作记录。")
      }
      if let data = record.response { return try decoder.decode(BridgeResponse.self, from: data) }
      return BridgeResponse(ok: false, status: record.state == "executing" ? "unknown" : record.state,
        message: record.error ?? "操作结果待核查；不要重复写入。", batchId: id,
        details: ["nextAction": "检查该批次审计记录及 Apple 实际事项；不得重新创建"])
    }
    if request.action == "diagnostics" {
      var response = status(request)
      response.details?["protocolVersion"] = "2"
      response.details?["journalVersion"] = "2"
      response.details?["earlyReminder"] = FileManager.default.isExecutableFile(atPath:
        ReminderKitPrivateService.defaultExecutable.path) ? "installed; probe required before write" : "missing"
      return response
    }
    let mutations = ["event.create", "event.update", "event.patch", "event.delete",
      "reminder.create", "reminder.update", "reminder.patch", "reminder.delete", "reminder.complete",
      "batch.commit", "batch.rollback"]
    if mutations.contains(request.action), request.dryRun == true, request.action != "batch.rollback" {
      var previewRequest = request
      previewRequest.batchId = request.batchId ?? UUID().uuidString.lowercased()
      let response = try dispatch(previewRequest)
      var canonical = previewRequest; canonical.requestId = nil; canonical.confirmed = nil; canonical.dryRun = nil
      let before = try targetSnapshot(previewRequest)
      try journal.write("single-preview:" + previewRequest.batchId!, SinglePreview(
        digest: OperationJournal.digest(try OperationJournal.encode(canonical)), before: before,
        analysis: try previewDigest(response)))
      var result = response; result.batchId = previewRequest.batchId
      return result
    }
    guard mutations.contains(request.action) else { return try dispatch(request) }
    return try MutationCoordinator(journal: journal).perform(request, preflight: { id, digest in
    if !request.action.hasSuffix(".create"), request.confirmed != true {
      throw BridgeError.confirmationRequired("此操作需要对已展示内容的明确确认。")
    }
    if request.action == "batch.commit" { _ = try self.checkedBatch(request) }
    if request.action != "batch.commit" && request.action != "batch.rollback" {
      guard let saved = try journal.read("single-preview:" + id, as: SinglePreview.self),
        saved.digest == digest, try saved.before == targetSnapshot(request) else {
        throw BridgeError.confirmationRequired("缺少对应预览或原事项已变化；重新预览。")
      }
      var check = request; check.dryRun = true
      guard try previewDigest(dispatch(check)) == saved.analysis else {
        throw BridgeError.confirmationRequired("预览结果已变化；重新预览。")
      }
    }
    }, execute: { try self.dispatch(request) })
  }

  private func dispatch(_ request: BridgeRequest) throws -> BridgeResponse {
    switch request.action {
    case "status": return status(request)
    case "setup": return try setup(request)
    case "event.list": return try listEvents(request)
    case "event.create": return try createOne(request, expectedKind: .event)
    case "event.patch": return try patchOne(request, expectedKind: .event)
    case "reminder.patch": return try patchOne(request, expectedKind: .reminder)
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

  private func recordedRollbackResponse(for id: String) throws -> BridgeResponse? {
    guard let record = try journal.read("operation:rollback:" + id, as: OperationRecord.self) else {
      return nil
    }
    var response: BridgeResponse
    if let data = record.response {
      response = try decoder.decode(BridgeResponse.self, from: data)
    } else {
      response = BridgeResponse(ok: false, status: "unknown",
        message: record.error ?? "回滚结果待核查；不要重复写入。", batchId: id,
        details: ["nextAction": "检查该批次回滚记录及 Apple 实际事项；不得重新执行回滚"])
    }
    var details = response.details ?? [:]
    details["operation"] = "batch.rollback"
    response.details = details
    return response
  }

  private func reconcile(_ request: BridgeRequest) throws -> BridgeResponse {
    guard let id = request.batchId else { throw BridgeError.notFound("缺少操作意图。") }
    if let rollback = try recordedRollbackResponse(for: id) { return rollback }
    guard var record = try journal.read("operation:" + id, as: OperationRecord.self),
      let original = try journal.read("request:operation:" + id, as: BridgeRequest.self) else {
      throw BridgeError.notFound("缺少操作意图。")
    }
    if record.state == "committed", let response = record.response { return try decoder.decode(BridgeResponse.self, from: response) }
    let expected = original.action == "batch.commit" ? (original.items?.count ?? 0) : 1
    let expectedAction: String?
    switch original.action {
    case "batch.commit", "event.create", "reminder.create": expectedAction = "create"
    case "event.update", "event.patch", "reminder.update", "reminder.patch": expectedAction = "update"
    case "event.delete", "reminder.delete": expectedAction = "delete"
    case "reminder.complete": expectedAction = "complete"
    default: expectedAction = nil
    }
    guard let expectedAction else { return unknownReconciliation(id: id, expected: expected, verified: []) }
    let operations: [AuditOperation]
    do { operations = try audit.operations(for: id) }
    catch { return unknownReconciliation(id: id, expected: expected, verified: []) }
    var verified: [ItemSummary] = []
    do {
      for operation in operations {
        guard operation.action == expectedAction else {
          return unknownReconciliation(id: id, expected: expected, verified: verified)
        }
        let after = try decodeSnapshot(operation.afterJSON)
        let before = try decodeSnapshot(operation.beforeJSON)
        guard let kind = ItemKind(rawValue: operation.entityType) else { continue }
        switch operation.action {
        case "create", "update", "complete":
          guard let after else { continue }
          try validateRecoverySnapshot(after, kind: kind)
          let lookup = try recovery.lookup(id: operation.calendarItemId,
            externalId: operation.externalId, snapshot: after, kind: kind)
          if case .found(let item) = lookup {
            let actual = try item.currentSnapshot()
            if actual == after { verified.append(actual.summary) }
          }
        case "delete":
          guard let before else { continue }
          try validateRecoverySnapshot(before, kind: kind)
          let lookup = try recovery.lookup(id: operation.calendarItemId,
            externalId: operation.externalId, snapshot: before, kind: kind)
          if case .absent = lookup { verified.append(before.summary) }
        default: continue
        }
      }
    } catch {
      return unknownReconciliation(id: id, expected: expected, verified: verified)
    }
    guard expected > 0, operations.count == expected, verified.count == expected else {
      return unknownReconciliation(id: id, expected: expected, verified: verified)
    }
    let response = BridgeResponse(ok: true, status: "committed", batchId: id, items: verified)
    record.state = "committed"; record.response = try OperationJournal.encode(response)
    try journal.write("operation:" + id, record)
    return response
  }

  private func unknownReconciliation(id: String, expected: Int, verified: [ItemSummary]) -> BridgeResponse {
    BridgeResponse(ok: false, status: "unknown", message: "无法证明全部写入完成；未重试或更改 Apple 事项。",
      batchId: id, items: verified, details: ["expected": String(expected), "verified": String(verified.count),
        "nextAction": "核查未完成写入意图；不要以新 batchId 重建"])
  }

  private func targetSnapshot(_ request: BridgeRequest) throws -> ItemSnapshot? {
    guard let selector = request.selector else { return nil }
    return try reliableSnapshot(findItem(selector, kind: request.action.hasPrefix("event.") ? .event : .reminder))
  }
  private func previewDigest(_ response: BridgeResponse) throws -> String {
    let values = [response.items ?? [], response.conflicts ?? [], response.duplicates ?? []]
    return OperationJournal.digest(try OperationJournal.encode(values.map { $0.sorted { $0.id < $1.id } }))
  }

  private func reliableSnapshot(_ item: EKCalendarItem, sourceRef: String? = nil) throws -> ItemSnapshot {
    var result = snapshot(item, sourceRef: sourceRef)
    if item is EKReminder {
      result.summary.earlyReminder = try ReminderKitPrivateService.readEarlyReminder(reminderID: item.calendarItemIdentifier)
    }
    return result
  }

  private func recordIntent(_ batchId: String, action: String, before: ItemSnapshot?, draft: ItemDraft?) throws {
    let key = "intents:" + batchId
    var intents = try journal.read(key, as: [MutationIntent].self) ?? []
    intents.append(MutationIntent(action: action, before: before, draft: draft))
    try journal.write(key, intents)
  }

  private func requireRecoverable(_ item: EKCalendarItem) throws {
    guard item.recurrenceRules?.isEmpty != false, (item as? EKEvent)?.isDetached != true else {
      throw BridgeError.invalidRequest("暂不支持可恢复的重复系列修改；未写入。")
    }
  }

  private func analysisDigest(_ drafts: [ItemDraft]) throws -> String {
    var parts: [String] = []
    for draft in drafts {
      let result = try analyze(draft, excluding: nil)
      let ids = (result.conflicts + result.duplicates).sorted { $0.id < $1.id }
      parts.append(OperationJournal.digest(try OperationJournal.encode(ids)))
      parts.append(draft.kind == .event ? try defaultEventCalendar().calendarIdentifier : try defaultReminderCalendar().calendarIdentifier)
    }
    return OperationJournal.digest(try OperationJournal.encode(parts))
  }

  private func patchOne(_ request: BridgeRequest, expectedKind: ItemKind) throws -> BridgeResponse {
    guard let selector = request.selector, let patch = request.patch, let id = request.batchId else {
      throw BridgeError.invalidRequest("patch 需要 selector、patch 和稳定 batchId。")
    }
    let existing = try findItem(selector, kind: expectedKind)
    try requireRecoverable(existing)
    let before = try reliableSnapshot(existing)
    var draft = try patch.applying(to: snapshotToDraft(before))
    if patch.alerts != nil || patch.clear?.contains("alerts") == true {
      draft.earlyReminder = patch.earlyReminder
    }
    if patch.alerts != nil || patch.earlyReminder != nil || patch.clear?.contains("alerts") == true {
      draft = try withResolvedAlerts(draft)
    }
    if request.dryRun == true {
      try journal.write("patch:" + id, PatchPreview(before: before, draft: draft))
    } else {
      guard let saved = try journal.read("patch:" + id, as: PatchPreview.self),
        saved.before == before, saved.draft == draft else {
        throw BridgeError.confirmationRequired("原事项或修改内容已变化，重新预览。")
      }
    }
    var update = request; update.item = draft
    return try updateOne(update, expectedKind: expectedKind)
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
    if draft.kind == .reminder { try ReminderKitPrivateService.probe() }
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
    if request.patch == nil { draft = try withResolvedAlerts(draft) }
    let existing = try findItem(selector, kind: expectedKind)
    try requireRecoverable(existing)
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
    guard let selector = request.selector else {
      throw BridgeError.invalidRequest("delete 缺少 selector。")
    }
    let existing = try findItem(selector, kind: expectedKind)
    try requireRecoverable(existing)
    let batchId = request.batchId ?? UUID().uuidString.lowercased()
    let before = try reliableSnapshot(existing)
    if request.dryRun == true { return BridgeResponse(ok: true, status: "preview", items: [before.summary]) }
    guard request.confirmed == true else { throw BridgeError.confirmationRequired("删除前必须确认。") }
    try audit.beginBatch(id: batchId, action: request.action)
    try recordIntent(batchId, action: "delete", before: before, draft: nil)
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
    guard let selector = request.selector else {
      throw BridgeError.invalidRequest("complete 缺少 selector。")
    }
    guard let reminder = try findItem(selector, kind: .reminder) as? EKReminder else {
      throw BridgeError.notFound("找不到待办。")
    }
    try requireRecoverable(reminder)
    let batchId = request.batchId ?? UUID().uuidString.lowercased()
    let before = try reliableSnapshot(reminder)
    if request.dryRun == true { return BridgeResponse(ok: true, status: "preview", items: [before.summary]) }
    guard request.confirmed == true else { throw BridgeError.confirmationRequired("完成前必须确认。") }
    try audit.beginBatch(id: batchId, action: request.action)
    try recordIntent(batchId, action: "complete", before: before, draft: nil)
    reminder.isCompleted = true
    reminder.completionDate = Date()
    do { try store.save(reminder, commit: true) } catch {
      throw BridgeError.eventKit(error.localizedDescription)
    }
    let after = try reliableSnapshot(reminder)
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
    let id = request.batchId ?? UUID().uuidString.lowercased()
    for draft in drafts where draft.kind == .reminder { try ReminderKitPrivateService.probe() }
    guard try journal.read("operation:" + id, as: OperationRecord.self) == nil else {
      throw BridgeError.invalidRequest("batchId 已用于写入；请查询 operation.status。")
    }
    try journal.write("preview:" + id, BatchPreview(requested: rawItems, drafts: drafts,
      analysis: try analysisDigest(drafts)))
    return BridgeResponse(
      ok: true,
      status: conflicts.isEmpty && duplicates.isEmpty ? "preview" : "needs_confirmation",
      requestId: request.requestId,
      batchId: id,
      items: drafts.enumerated().map { draftSummary($0.element, id: "draft-\($0.offset + 1)") },
      conflicts: unique(conflicts),
      duplicates: unique(duplicates)
    )
  }

  private func checkedBatch(_ request: BridgeRequest) throws -> [ItemDraft] {
    guard request.confirmed == true else { throw BridgeError.confirmationRequired("批量写入前必须确认预览。") }
    guard let rawItems = request.items, !rawItems.isEmpty else {
      throw BridgeError.invalidRequest("batch.commit 需要非空 items。")
    }
    guard let batchId = request.batchId,
      let preview = try journal.read("preview:" + batchId, as: BatchPreview.self) else {
      throw BridgeError.invalidRequest("缺少已保存预览；请先 batch.preview。")
    }
    let normalized = preview.drafts
    guard rawItems == preview.drafts || rawItems == preview.requested else { throw BridgeError.invalidRequest("内容与预览不符；重新预览。") }
    guard try analysisDigest(normalized) == preview.analysis else {
      throw BridgeError.confirmationRequired("冲突或目标容器已变化；重新预览。")
    }
    for draft in normalized where draft.kind == .reminder { try ReminderKitPrivateService.probe() }
    return normalized
  }

  private func commitBatch(_ request: BridgeRequest) throws -> BridgeResponse {
    let normalized = try checkedBatch(request)
    let batchId = request.batchId!
    try audit.beginBatch(id: batchId, action: request.action)
    var created: [ItemSummary] = []
    do {
      for draft in normalized {
        created.append(try create(draft, batchId: batchId))
      }
    } catch {
      let original = String(describing: error)
      do { _ = try rollback(batchId) }
      catch { throw BridgeError.eventKit("原始错误：\(original)；回滚错误：\(error)；结果待核查。") }
      throw BridgeError.eventKit("\(original)；已记录操作已回滚，仍须核查未完成的写入意图。")
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
    if var original = try journal.read("operation:" + batchId, as: OperationRecord.self) {
      original.state = "rolled_back"
      original.response = try OperationJournal.encode(BridgeResponse(ok: true, status: "rolled_back", batchId: batchId, items: restored))
      try journal.write("operation:" + batchId, original)
    }
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
      guard let kind = ItemKind(rawValue: operation.entityType) else {
        throw BridgeError.eventKit("审计事项类型未知；停止回滚。")
      }
      let progressKey = "rollback-step:\(batchId):\(operation.id)"
      if let state = try journal.read(progressKey, as: String.self) {
        if state == "done" { continue }
        throw BridgeError.eventKit("回滚步骤 \(operation.id) 结果待核查，未重复执行。")
      }
      switch operation.action {
      case "create":
        guard let after else { throw BridgeError.eventKit("创建审计缺少写入后快照；停止回滚。") }
        try validateRecoverySnapshot(after, kind: kind)
        let lookup = try recovery.lookup(id: operation.calendarItemId,
          externalId: operation.externalId, snapshot: after, kind: kind)
        switch lookup {
        case .found(let item):
          guard try item.currentSnapshot() == after else {
            throw BridgeError.confirmationRequired("事项在写入后已变化；停止回滚。")
          }
          guard let externalId = operation.externalId ?? after.summary.externalId,
            !externalId.isEmpty else {
            throw BridgeError.eventKit("缺少外部标识，无法验证删除后的缺席；停止回滚。")
          }
          try journal.write(progressKey, "executing")
          try item.remove("future")
          let check = try recovery.lookup(id: operation.calendarItemId,
            externalId: operation.externalId, snapshot: after, kind: kind)
          guard case .absent = check else { throw BridgeError.eventKit("删除后未能证明事项消失。") }
        case .absent:
          try journal.write(progressKey, "executing")
        }
        results.append(after.summary)
      case "update", "complete":
        guard let before, let after else {
          throw BridgeError.eventKit("修改审计缺少快照；停止回滚。")
        }
        try validateRecoverySnapshot(before, kind: kind)
        try validateRecoverySnapshot(after, kind: kind)
        try recovery.validateRestoreContainer(before)
        let lookup = try recovery.lookup(id: operation.calendarItemId,
          externalId: operation.externalId, snapshot: after, kind: kind)
        guard case .found(let item) = lookup else {
          throw BridgeError.confirmationRequired("原事项已消失；停止回滚，避免重建用户删除的事项。")
        }
        guard try item.currentSnapshot() == after else {
          throw BridgeError.confirmationRequired("事项在写入后已变化；停止回滚。")
        }
        try journal.write(progressKey, "executing")
        let restored = try item.restore(before)
        let check = try recovery.lookup(id: restored.id,
          externalId: restored.externalId, snapshot: before, kind: kind)
        guard case .found(let checked) = check,
          try checked.currentSnapshot() == before else {
          throw BridgeError.eventKit("恢复后回读不一致；结果待核查。")
        }
        results.append(restored)
      case "delete":
        guard let before, after == nil else {
          throw BridgeError.eventKit("删除审计缺少可靠快照；停止回滚。")
        }
        try validateRecoverySnapshot(before, kind: kind)
        try recovery.validateRestoreContainer(before)
        let lookup = try recovery.lookup(id: operation.calendarItemId,
          externalId: operation.externalId, snapshot: before, kind: kind)
        switch lookup {
        case .found(let item):
          guard try item.currentSnapshot() == before else {
            throw BridgeError.confirmationRequired("原事项已变化；停止回滚。")
          }
          try journal.write(progressKey, "executing")
          results.append(before.summary)
        case .absent:
          try journal.write(progressKey, "executing")
          let restored = try recovery.recreateDeleted(before)
          let check = try recovery.lookup(id: restored.id,
            externalId: restored.externalId, snapshot: before, kind: kind)
          guard case .found(let item) = check,
            try sameRestoredContent(item.currentSnapshot(), before) else {
            throw BridgeError.eventKit("重建后回读不一致；结果待核查。")
          }
          results.append(restored)
        }
      default:
        throw BridgeError.eventKit("审计动作未知；停止回滚。")
      }
      try journal.write(progressKey, "done")
    }
    try audit.markRolledBack(batchId)
    return results
  }

  private func validateRecoverySnapshot(_ snapshot: ItemSnapshot, kind: ItemKind) throws {
    guard snapshot.summary.kind == kind,
      let container = snapshot.calendarIdentifier, !container.isEmpty,
      kind != .reminder || snapshot.summary.completed != nil else {
      throw BridgeError.eventKit("旧快照缺少原容器或完成状态；停止恢复。")
    }
  }

  private func sameRestoredContent(_ actual: ItemSnapshot, _ original: ItemSnapshot) -> Bool {
    var normalized = actual
    normalized.summary.id = original.summary.id
    normalized.summary.externalId = original.summary.externalId
    return normalized == original
  }

  private func create(_ draft: ItemDraft, batchId: String?) throws -> ItemSummary {
    if draft.kind == .reminder { try ReminderKitPrivateService.probe() }
    if let batchId { try recordIntent(batchId, action: "create", before: nil, draft: draft) }
    switch draft.kind {
    case .event:
      try requireAccess(.event)
      let event = EKEvent(eventStore: store)
      event.calendar = try defaultEventCalendar()
      try apply(draft, to: event)
      do { try store.save(event, span: .thisEvent, commit: true) } catch {
        throw BridgeError.eventKit(error.localizedDescription)
      }
      let after = try reliableSnapshot(event, sourceRef: draft.sourceRef)
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
      var after = try reliableSnapshot(reminder, sourceRef: draft.sourceRef)
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
    let before = try reliableSnapshot(existing)
    if draft.kind == .reminder { try ReminderKitPrivateService.probe() }
    try recordIntent(batchId, action: "update", before: before, draft: draft)
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
    var after = try reliableSnapshot(existing, sourceRef: draft.sourceRef)
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

  package func lookup(id: String?, externalId: String?, snapshot: ItemSnapshot?, kind: ItemKind)
    throws -> RecordedLookup
  {
    guard let snapshot else { throw BridgeError.eventKit("缺少来源快照；无法确认事项身份。") }
    try validateRecoverySnapshot(snapshot, kind: kind)
    let calendar = try originalCalendar(snapshot)
    guard let id = id ?? (snapshot.summary.id.isEmpty ? nil : snapshot.summary.id) else {
      throw BridgeError.eventKit("缺少事项标识；无法确认其已消失。")
    }
    store.refreshSourcesIfNecessary()
    if let item = store.calendarItem(withIdentifier: id) {
      guard ((kind == .event && item is EKEvent) || (kind == .reminder && item is EKReminder)),
        item.calendar?.calendarIdentifier == calendar.calendarIdentifier else {
        throw BridgeError.eventKit("事项类型或原容器不匹配；结果待核查。")
      }
      return .found(RecordedItem(
        currentSnapshot: { try self.reliableSnapshot(item, sourceRef: snapshot.sourceRef) },
        remove: { scope in
          try self.requireRecoverable(item)
          try self.remove(item, scope: scope)
        },
        restore: { before in try self.restore(before, onto: item) }
      ))
    }
    guard let externalId = externalId ?? snapshot.summary.externalId, !externalId.isEmpty else {
      throw BridgeError.eventKit("缺少外部标识，无法证明事项已消失。")
    }
    if !store.calendarItems(withExternalIdentifier: externalId).isEmpty {
      throw BridgeError.eventKit("外部标识仍有匹配事项；无法证明原事项已消失。")
    }
    return .absent
  }

  package func validateRestoreContainer(_ snapshot: ItemSnapshot) throws {
    try validateRecoverySnapshot(snapshot, kind: snapshot.summary.kind)
    _ = try originalCalendar(snapshot)
    if snapshot.summary.kind == .reminder { try ReminderKitPrivateService.probe() }
    _ = try CalendarRules.validated(snapshotToDraft(snapshot))
  }

  private func originalCalendar(_ snapshot: ItemSnapshot) throws -> EKCalendar {
    let kind = snapshot.summary.kind
    try requireAccess(kind == .event ? .event : .reminder)
    guard let identifier = snapshot.calendarIdentifier,
      let calendar = store.calendar(withIdentifier: identifier),
      calendar.allowedEntityTypes.contains(kind == .event ? .event : .reminder),
      calendar.allowsContentModifications else {
      throw BridgeError.eventKit("原容器不可用、类型不符或不可写；停止恢复。")
    }
    return calendar
  }

  package func recreateDeleted(_ snapshot: ItemSnapshot) throws -> ItemSummary {
    try validateRestoreContainer(snapshot)
    let calendar = try originalCalendar(snapshot)
    let draft = try CalendarRules.validated(snapshotToDraft(snapshot))
    switch draft.kind {
    case .event:
      let event = EKEvent(eventStore: store)
      event.calendar = calendar
      try apply(draft, to: event)
      do { try store.save(event, span: .thisEvent, commit: true) }
      catch { throw BridgeError.eventKit(error.localizedDescription) }
      return try reliableSnapshot(event, sourceRef: snapshot.sourceRef).summary
    case .reminder:
      let reminder = EKReminder(eventStore: store)
      reminder.calendar = calendar
      try apply(draft, to: reminder)
      reminder.isCompleted = snapshot.summary.completed!
      reminder.completionDate = snapshot.summary.completed == true ? Date() : nil
      do { try store.save(reminder, commit: true) }
      catch { throw BridgeError.eventKit(error.localizedDescription) }
      try ReminderKitPrivateService.setEarlyReminder(
        reminderID: reminder.calendarItemIdentifier, spec: draft.earlyReminder)
      return try reliableSnapshot(reminder, sourceRef: snapshot.sourceRef).summary
    }
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
    try validateRestoreContainer(snapshot)
    let calendar = try originalCalendar(snapshot)
    try requireRecoverable(item)
    let draft = snapshotToDraft(snapshot)
    if let event = item as? EKEvent {
      event.calendar = calendar
      try apply(draft, to: event)
      do { try store.save(event, span: .thisEvent, commit: true) } catch {
        throw BridgeError.eventKit(error.localizedDescription)
      }
    } else if let reminder = item as? EKReminder {
      reminder.calendar = calendar
      try apply(draft, to: reminder)
      reminder.isCompleted = snapshot.summary.completed!
      reminder.completionDate = snapshot.summary.completed == true ? Date() : nil
      do { try store.save(reminder, commit: true) } catch {
        throw BridgeError.eventKit(error.localizedDescription)
      }
      try ReminderKitPrivateService.setEarlyReminder(
        reminderID: reminder.calendarItemIdentifier, spec: draft.earlyReminder)
    }
    return try reliableSnapshot(item, sourceRef: snapshot.sourceRef).summary
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
      calendarIdentifier: item.calendar?.calendarIdentifier,
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
    guard let item = store.calendarItem(withIdentifier: id) else {
      throw BridgeError.eventKit("写入后无法回读 \(id)，结果待核查。")
    }
    let actual = summary(item)
    if fallback.kind == .reminder, fallback.earlyReminder != nil {
      var adjusted = actual
      adjusted.earlyReminder = try ReminderKitPrivateService.readEarlyReminder(reminderID: id)
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
    guard semaphore.wait(timeout: .now() + 30) == .success else {
      throw BridgeError.eventKit("系统请求超时；不要在原请求仍等待时重试。")
    }
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
    guard semaphore.wait(timeout: .now() + 30) == .success else {
      throw BridgeError.eventKit("系统请求超时；不要在原请求仍等待时重试。")
    }
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
    let selected = try BridgeConfiguration.load().eventCalendarId
    guard let calendar = selected == nil ? store.defaultCalendarForNewEvents : store.calendars(for: .event).first(where: { $0.calendarIdentifier == selected }) else {
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
    let selected = try BridgeConfiguration.load().reminderCalendarId
    guard let calendar = selected == nil ? store.defaultCalendarForNewReminders() : store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == selected }) else {
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

private struct BatchPreview: Codable {
  var requested: [ItemDraft]
  var drafts: [ItemDraft]
  var analysis: String
}
private struct MutationIntent: Codable {
  var action: String
  var before: ItemSnapshot?
  var draft: ItemDraft?
}
private struct PatchPreview: Codable {
  var before: ItemSnapshot
  var draft: ItemDraft
}

private struct SinglePreview: Codable {
  var digest: String
  var before: ItemSnapshot?
  var analysis: String
}
