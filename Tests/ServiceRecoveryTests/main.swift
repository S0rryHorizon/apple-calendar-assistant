import CalendarBridgeCore
import CalendarBridgeRuntime
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
  let description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw TestFailure(description: message) }
}

private final class FakeRecovery: RecoveryBackend {
  var items: [String: ItemSnapshot] = [:]
  var containers: Set<String> = ["calendar-A", "calendar-B"]
  var writableContainers: Set<String> = ["calendar-A", "calendar-B"]
  var lookupFailure: BridgeError?
  var failAfterRecreate = false
  var lookupCount = 0
  var removeCount = 0
  var restoreCount = 0
  var recreateCount = 0
  var usedContainer: String?

  func lookup(id: String?, externalId: String?, snapshot: ItemSnapshot?, kind: ItemKind)
    throws -> RecordedLookup
  {
    lookupCount += 1
    if let lookupFailure { throw lookupFailure }
    guard let id, let value = items[id] else { return .absent }
    guard value.summary.kind == kind else { throw BridgeError.eventKit("synthetic kind mismatch") }
    return .found(RecordedItem(
      currentSnapshot: {
        guard let current = self.items[id] else { throw BridgeError.eventKit("synthetic item vanished") }
        return current
      },
      remove: { _ in
        self.removeCount += 1
        self.items.removeValue(forKey: id)
      },
      restore: { before in
        self.restoreCount += 1
        self.items[id] = before
        self.usedContainer = before.calendarIdentifier
        return before.summary
      }
    ))
  }

  func validateRestoreContainer(_ snapshot: ItemSnapshot) throws {
    guard let container = snapshot.calendarIdentifier,
      containers.contains(container), writableContainers.contains(container) else {
      throw BridgeError.eventKit("synthetic original container unavailable")
    }
  }

  func recreateDeleted(_ snapshot: ItemSnapshot) throws -> ItemSummary {
    try validateRestoreContainer(snapshot)
    recreateCount += 1
    usedContainer = snapshot.calendarIdentifier
    var restored = snapshot
    restored.summary.id = "restored-\(recreateCount)"
    restored.summary.externalId = "synthetic-restored-\(recreateCount)"
    items[restored.summary.id] = restored
    if failAfterRecreate { throw BridgeError.storage("synthetic audit failure after write") }
    return restored.summary
  }
}

private final class Harness {
  let directory: URL
  let journal: OperationJournal
  let audit: AuditStore
  let backend: FakeRecovery
  let service: EventKitService

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "calendarbridge-recovery-\(UUID().uuidString)")
    journal = try OperationJournal(directory: directory.appendingPathComponent("journal"))
    audit = try AuditStore(directory: directory.appendingPathComponent("audit"))
    backend = FakeRecovery()
    service = EventKitService(journal: journal, audit: audit, recovery: backend)
  }

  func cleanUp() { try? FileManager.default.removeItem(at: directory) }

  func record(_ id: String, action: String, kind: ItemKind,
    before: ItemSnapshot? = nil, after: ItemSnapshot? = nil) throws {
    try audit.beginBatch(id: id, action: action)
    try audit.record(batchId: id, action: action, entityType: kind,
      calendarItemId: after?.summary.id ?? before?.summary.id,
      externalId: after?.summary.externalId ?? before?.summary.externalId,
      before: before, after: after)
  }

  func rollback(_ id: String) throws -> BridgeResponse {
    try service.handle(BridgeRequest(action: "batch.rollback", confirmed: true, batchId: id))
  }

  func prepareReconcile(_ id: String, action: String) throws {
    try journal.write("operation:" + id, OperationRecord(digest: "synthetic", state: "executing"))
    try journal.write("request:operation:" + id, BridgeRequest(action: action, batchId: id))
  }

  func prepareCommitted(_ id: String, action: String) throws {
    try prepareReconcile(id, action: action)
    let response = BridgeResponse(ok: true, status: "committed", batchId: id)
    try journal.write("operation:" + id, OperationRecord(digest: "synthetic", state: "committed",
      response: try OperationJournal.encode(response)))
  }
}

private func snapshot(_ kind: ItemKind, id: String, container: String?,
  completed: Bool? = nil) -> ItemSnapshot {
  let summary = ItemSummary(id: id, externalId: "external-\(id)", kind: kind,
    title: "Invented item", start: kind == .event ? "2030-01-01T10:00:00+08:00" : nil,
    end: kind == .event ? "2030-01-01T11:00:00+08:00" : nil,
    due: kind == .reminder ? "2030-01-01T10:00:00+08:00" : nil,
    completed: completed)
  return ItemSnapshot(summary: summary, calendarIdentifier: container,
    notes: "Synthetic only", sourceRef: "synthetic-source")
}

private func testCreateRollbackFoundAndAbsent() throws {
  for found in [true, false] {
    let h = try Harness(); defer { h.cleanUp() }
    let after = snapshot(.event, id: "created", container: "calendar-A")
    try h.record("create-\(found)", action: "create", kind: .event, after: after)
    if found { h.backend.items[after.summary.id] = after }
    let result = try h.rollback("create-\(found)")
    try expect(result.status == "rolled_back", "create rollback should finish")
    try expect(h.backend.removeCount == (found ? 1 : 0), "only a found item may be removed")
    try expect(h.backend.items.isEmpty, "created item should be absent")
    try expect(try h.audit.operations(for: "create-\(found)").isEmpty,
      "audit should be marked rolled back")
  }
}

private func testAmbiguousOrFailedLookupNeverMeansAbsent() throws {
  for failure in ["ambiguous", "query failed"] {
    let h = try Harness(); defer { h.cleanUp() }
    let after = snapshot(.event, id: "created", container: "calendar-A")
    try h.record("lookup-\(failure)", action: "create", kind: .event, after: after)
    h.backend.lookupFailure = .eventKit(failure)
    let first = try h.rollback("lookup-\(failure)")
    let calls = h.backend.lookupCount
    let replay = try h.rollback("lookup-\(failure)")
    try expect(first.status == "unknown" && replay.status == "unknown", "lookup uncertainty must stay unknown")
    try expect(h.backend.lookupCount == calls, "same key must not retry unknown rollback")
    try expect(h.backend.removeCount == 0, "uncertain lookup must not remove")
    try expect(try h.audit.operations(for: "lookup-\(failure)").count == 1,
      "audit must remain available")
  }
}

private func testDeleteReconcileDistinguishesErrorFromAbsent() throws {
  let h = try Harness(); defer { h.cleanUp() }
  let before = snapshot(.event, id: "deleted", container: "calendar-A")
  try h.record("delete-reconcile", action: "delete", kind: .event, before: before)
  try h.prepareReconcile("delete-reconcile", action: "event.delete")
  h.backend.lookupFailure = .eventKit("query failed")
  let uncertain = try h.service.handle(BridgeRequest(action: "operation.reconcile", batchId: "delete-reconcile"))
  try expect(uncertain.status == "unknown", "failed lookup cannot prove deletion")
  try expect(try h.journal.read("operation:delete-reconcile", as: OperationRecord.self)?.state == "executing",
    "uncertain reconciliation must retain intent")
  h.backend.lookupFailure = nil
  let absent = try h.service.handle(BridgeRequest(action: "operation.reconcile", batchId: "delete-reconcile"))
  try expect(absent.status == "committed", "explicit absent lookup proves recorded delete")
  try expect(h.backend.recreateCount == 0, "reconcile must be read-only")

  let mismatch = try Harness(); defer { mismatch.cleanUp() }
  try mismatch.record("mismatched-action", action: "delete", kind: .event, before: before)
  try mismatch.prepareReconcile("mismatched-action", action: "event.create")
  let unproven = try mismatch.service.handle(BridgeRequest(action: "operation.reconcile", batchId: "mismatched-action"))
  try expect(unproven.status == "unknown", "audit action must match recorded intent")
  try expect(try mismatch.journal.read("operation:mismatched-action", as: OperationRecord.self)?.state == "executing",
    "mismatched reconciliation must retain intent")
}

private func testDeleteRestoreUsesOriginalListAndCompletion() throws {
  let h = try Harness(); defer { h.cleanUp() }
  let before = snapshot(.reminder, id: "deleted-reminder", container: "calendar-A", completed: true)
  try h.record("delete-reminder", action: "delete", kind: .reminder, before: before)
  let result = try h.rollback("delete-reminder")
  try expect(result.status == "rolled_back", "valid deleted reminder should restore")
  try expect(h.backend.usedContainer == "calendar-A", "restore must use original list A")
  try expect(h.backend.items["restored-1"]?.summary.completed == true,
    "completed reminder must stay completed")
}

private func testUpdateRestoresOriginalContainer() throws {
  let h = try Harness(); defer { h.cleanUp() }
  let before = snapshot(.event, id: "moved-event", container: "calendar-A")
  let after = snapshot(.event, id: "moved-event", container: "calendar-B")
  try h.record("update-event", action: "update", kind: .event, before: before, after: after)
  h.backend.items[after.summary.id] = after
  let result = try h.rollback("update-event")
  try expect(result.status == "rolled_back", "valid update should restore")
  try expect(h.backend.restoreCount == 1 && h.backend.usedContainer == "calendar-A",
    "update must restore original container A")
}

private func testLegacyAndInvalidSnapshotsStopBeforeRestore() throws {
  let legacy = snapshot(.event, id: "old", container: nil)
  let decoded = try JSONDecoder().decode(ItemSnapshot.self, from: JSONEncoder().encode(legacy))
  try expect(decoded.calendarIdentifier == nil, "old snapshot must remain decodable")
  let cases: [(String, ItemSnapshot, Set<String>, Set<String>)] = [
    ("legacy", legacy, ["calendar-A"], ["calendar-A"]),
    ("container-gone", snapshot(.event, id: "missing", container: "calendar-A"), ["calendar-B"], ["calendar-B"]),
    ("container-readonly", snapshot(.event, id: "readonly", container: "calendar-A"), ["calendar-A"], ["calendar-B"]),
    ("completion-unknown", snapshot(.reminder, id: "undated", container: "calendar-A"), ["calendar-A"], ["calendar-A"]),
  ]
  for (id, before, containers, writable) in cases {
    let h = try Harness(); defer { h.cleanUp() }
    h.backend.containers = containers
    h.backend.writableContainers = writable
    try h.record(id, action: "delete", kind: before.summary.kind, before: before)
    let operation = try h.audit.operations(for: id)[0]
    let result = try h.rollback(id)
    try expect(result.status == "unknown", "unsafe snapshot should remain unknown: \(id)")
    try expect(h.backend.recreateCount == 0, "unsafe snapshot must not restore: \(id)")
    try expect(h.backend.restoreCount == 0 && h.backend.removeCount == 0,
      "unsafe snapshot must not write: \(id)")
    try expect(try h.journal.read("rollback-step:\(id):\(operation.id)", as: String.self) == nil,
      "unsafe snapshot must stop before executing step: \(id)")
    try expect(try h.journal.read("operation:rollback:\(id)", as: OperationRecord.self)?.state == "unknown",
      "unsafe snapshot must not complete rollback journal: \(id)")
    try expect(try h.audit.operations(for: id).count == 1, "audit must remain: \(id)")
  }
}

private func testWriteThenFailureNeverRetriesSameKey() throws {
  let h = try Harness(); defer { h.cleanUp() }
  let before = snapshot(.event, id: "deleted", container: "calendar-A")
  try h.record("write-failure", action: "delete", kind: .event, before: before)
  h.backend.failAfterRecreate = true
  let first = try h.rollback("write-failure")
  let replay = try h.rollback("write-failure")
  try expect(first.status == "unknown" && replay.status == "unknown", "post-write failure must stay unknown")
  try expect(h.backend.recreateCount == 1, "same key must never write twice")
  try expect(try h.audit.operations(for: "write-failure").count == 1,
    "post-write failure must retain audit")
}

private func testRollbackFailureQueriesDoNotReturnOriginalSuccess() throws {
  let h = try Harness(); defer { h.cleanUp() }
  let id = "rollback-query-failure"
  let before = snapshot(.event, id: "deleted", container: "calendar-A")
  try h.record(id, action: "delete", kind: .event, before: before)
  try h.prepareCommitted(id, action: "event.delete")
  h.backend.failAfterRecreate = true
  let rollback = try h.rollback(id)
  try expect(rollback.status == "unknown" && h.backend.recreateCount == 1,
    "rollback must fail after its synthetic side effect")
  let lookupCount = h.backend.lookupCount
  for action in ["operation.status", "operation.reconcile"] {
    let result = try h.service.handle(BridgeRequest(action: action, batchId: id))
    try expect(!result.ok && result.status == "unknown" && result.batchId == id,
      "failed rollback must take precedence over original success: \(action)")
    try expect(result.details?["operation"] == "batch.rollback", "receipt must identify rollback")
    try expect(result.message == rollback.message, "query must preserve rollback failure evidence")
  }
  try expect(h.backend.recreateCount == 1 && h.backend.lookupCount == lookupCount,
    "rollback queries must not retry writes or inspect the original operation")
  try expect(try h.journal.read("operation:" + id, as: OperationRecord.self)?.state == "committed",
    "query must preserve the historical original receipt")
  try expect(try h.journal.read("operation:rollback:" + id, as: OperationRecord.self)?.state == "unknown",
    "query must retain unresolved rollback intent")
  try expect(try h.audit.operations(for: id).count == 1, "query must preserve recovery audit")
}

private func testExecutingRollbackQueriesStayUnknown() throws {
  let h = try Harness(); defer { h.cleanUp() }
  let id = "rollback-query-executing"
  try h.prepareCommitted(id, action: "event.delete")
  try h.journal.write("operation:rollback:" + id, OperationRecord(digest: "synthetic", state: "executing"))
  for action in ["operation.status", "operation.reconcile"] {
    let result = try h.service.handle(BridgeRequest(action: action, batchId: id))
    try expect(!result.ok && result.status == "unknown" && result.batchId == id,
      "interrupted rollback must stay unknown: \(action)")
    try expect(result.details?["operation"] == "batch.rollback", "pending receipt must identify rollback")
  }
  try expect(h.backend.lookupCount == 0 && h.backend.recreateCount == 0,
    "pending rollback queries must not access the backend")
  try expect(try h.journal.read("operation:rollback:" + id, as: OperationRecord.self)?.state == "executing",
    "query must not replace the interrupted intent")
}

private func testSuccessfulRollbackQueriesReturnRollbackReceipt() throws {
  for hasOriginalReceipt in [true, false] {
    let h = try Harness(); defer { h.cleanUp() }
    let id = "rollback-query-success"
    let before = snapshot(.event, id: "deleted", container: "calendar-A")
    try h.record(id, action: "delete", kind: .event, before: before)
    if hasOriginalReceipt { try h.prepareCommitted(id, action: "event.delete") }
    let rollback = try h.rollback(id)
    try expect(rollback.status == "rolled_back", "synthetic rollback should finish")
    let lookupCount = h.backend.lookupCount
    for action in ["operation.status", "operation.reconcile"] {
      let result = try h.service.handle(BridgeRequest(action: action, batchId: id))
      try expect(result.ok && result.status == "rolled_back" && result.batchId == id,
        "completed rollback must remain rolled back: \(action)")
      try expect(result.details?["operation"] == "batch.rollback", "completed receipt must identify rollback")
      try expect(result.items == rollback.items, "query must preserve restored items")
    }
    try expect(h.backend.recreateCount == 1 && h.backend.lookupCount == lookupCount,
      "completed rollback queries must not repeat recovery")
  }
}

private func testOriginalQueriesWithoutRollbackKeepTheirReceipt() throws {
  let h = try Harness(); defer { h.cleanUp() }
  let id = "original-query"
  try h.prepareCommitted(id, action: "event.delete")
  for action in ["operation.status", "operation.reconcile"] {
    let result = try h.service.handle(BridgeRequest(action: action, batchId: id))
    try expect(result.ok && result.status == "committed" && result.batchId == id,
      "original committed receipt must remain available: \(action)")
    try expect(result.details?["operation"] == nil, "original receipt must not be labelled rollback")
  }
  try expect(h.backend.lookupCount == 0, "stored original receipt should not access the backend")
}

private let scenarios: [(String, () throws -> Void)] = [
  ("create found and absent", testCreateRollbackFoundAndAbsent),
  ("ambiguous and query error", testAmbiguousOrFailedLookupNeverMeansAbsent),
  ("delete reconcile", testDeleteReconcileDistinguishesErrorFromAbsent),
  ("original list and completion", testDeleteRestoreUsesOriginalListAndCompletion),
  ("update original container", testUpdateRestoresOriginalContainer),
  ("legacy and invalid snapshots", testLegacyAndInvalidSnapshotsStopBeforeRestore),
  ("post-write failure", testWriteThenFailureNeverRetriesSameKey),
  ("rollback failure queries", testRollbackFailureQueriesDoNotReturnOriginalSuccess),
  ("executing rollback queries", testExecutingRollbackQueriesStayUnknown),
  ("successful rollback queries", testSuccessfulRollbackQueriesReturnRollbackReceipt),
  ("original queries without rollback", testOriginalQueriesWithoutRollbackKeepTheirReceipt),
]

private func controlledDemo() throws {
  let restored = try Harness(); defer { restored.cleanUp() }
  let before = snapshot(.reminder, id: "synthetic-reminder", container: "calendar-A", completed: true)
  try restored.record("synthetic-delete", action: "delete", kind: .reminder, before: before)
  let rollback = try restored.rollback("synthetic-delete")
  try expect(rollback.status == "rolled_back", "demo reminder rollback should finish")
  try expect(restored.backend.usedContainer == "calendar-A", "demo must restore original list")
  try expect(restored.backend.items["restored-1"]?.summary.completed == true,
    "demo must preserve completion")
  print("SYNTHETIC restore: \(rollback.status); original list=calendar-A; completed=true")

  let uncertain = try Harness(); defer { uncertain.cleanUp() }
  let created = snapshot(.event, id: "synthetic-event", container: "calendar-B")
  try uncertain.record("synthetic-create", action: "create", kind: .event, after: created)
  uncertain.backend.lookupFailure = .eventKit("synthetic query failure")
  let unknown = try uncertain.rollback("synthetic-create")
  try expect(unknown.status == "unknown", "demo query error must remain unknown")
  try expect(uncertain.backend.removeCount == 0, "demo must not remove on query error")
  try expect(try uncertain.audit.operations(for: "synthetic-create").count == 1,
    "demo must preserve uncertain audit")
  print("SYNTHETIC lookup failure: \(unknown.status); removals=0; audit retained")
}

if CommandLine.arguments.dropFirst() == ["--demo"] {
  do { try controlledDemo() }
  catch { print("FAIL: synthetic demo: \(error)"); exit(1) }
} else if CommandLine.arguments.count == 1 {
  var failures = 0
  for (name, scenario) in scenarios {
    do { try scenario(); print("PASS: \(name)") }
    catch { failures += 1; print("FAIL: \(name): \(error)") }
  }
  if failures > 0 { exit(1) }
  print("\(scenarios.count) synthetic service recovery scenarios passed")
} else {
  print("Usage: CalendarBridgeServiceTests [--demo]")
  exit(2)
}
