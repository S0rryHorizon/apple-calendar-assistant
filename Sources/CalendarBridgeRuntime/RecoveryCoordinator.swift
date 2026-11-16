import CalendarBridgeCore
import Foundation

/// Rollback and reconciliation of recorded operations. Works only from the
/// journal, the audit log and the RecoveryBackend boundary, so it never touches
/// EventKit directly and runs unchanged against the synthetic backend in tests.
struct RecoveryCoordinator {
  private let journal: OperationJournal
  private let audit: AuditStore
  private let backend: any RecoveryBackend
  private let decoder = JSONDecoder()

  init(journal: OperationJournal, audit: AuditStore, backend: any RecoveryBackend) {
    self.journal = journal
    self.audit = audit
    self.backend = backend
  }

  func recordedRollbackResponse(for id: String) throws -> BridgeResponse? {
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

  func reconcile(_ request: BridgeRequest) throws -> BridgeResponse {
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
          try Self.validateSnapshot(after, kind: kind)
          let lookup = try backend.lookup(id: operation.calendarItemId,
            externalId: operation.externalId, snapshot: after, kind: kind)
          if case .found(let item) = lookup {
            let actual = try item.currentSnapshot()
            if actual == after { verified.append(actual.summary) }
          }
        case "delete":
          guard let before else { continue }
          try Self.validateSnapshot(before, kind: kind)
          let lookup = try backend.lookup(id: operation.calendarItemId,
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

  func rollbackBatch(_ request: BridgeRequest) throws -> BridgeResponse {
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

  func rollback(_ batchId: String) throws -> [ItemSummary] {
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
        try Self.validateSnapshot(after, kind: kind)
        let lookup = try backend.lookup(id: operation.calendarItemId,
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
          let check = try backend.lookup(id: operation.calendarItemId,
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
        try Self.validateSnapshot(before, kind: kind)
        try Self.validateSnapshot(after, kind: kind)
        try backend.validateRestoreContainer(before)
        let lookup = try backend.lookup(id: operation.calendarItemId,
          externalId: operation.externalId, snapshot: after, kind: kind)
        guard case .found(let item) = lookup else {
          throw BridgeError.confirmationRequired("原事项已消失；停止回滚，避免重建用户删除的事项。")
        }
        guard try item.currentSnapshot() == after else {
          throw BridgeError.confirmationRequired("事项在写入后已变化；停止回滚。")
        }
        try journal.write(progressKey, "executing")
        let restored = try item.restore(before)
        let check = try backend.lookup(id: restored.id,
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
        try Self.validateSnapshot(before, kind: kind)
        try backend.validateRestoreContainer(before)
        let lookup = try backend.lookup(id: operation.calendarItemId,
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
          let restored = try backend.recreateDeleted(before)
          let check = try backend.lookup(id: restored.id,
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

  static func validateSnapshot(_ snapshot: ItemSnapshot, kind: ItemKind) throws {
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

  private func decodeSnapshot(_ json: String?) throws -> ItemSnapshot? {
    guard let json, let data = json.data(using: .utf8) else { return nil }
    return try decoder.decode(ItemSnapshot.self, from: data)
  }
}
