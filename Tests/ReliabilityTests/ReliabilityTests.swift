import Foundation
import CalendarBridgeCore

final class ReliabilityTests: TestCase {
  var directory: URL!
  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
  func request() -> BridgeRequest {
    BridgeRequest(action: "event.create", confirmed: true,
      item: ItemDraft(kind: .event, title: "Test", start: "2030-01-01T10:00:00+08:00"), batchId: "stable")
  }
  func testReplayDoesNotCallBackendOrPreflight() throws {
    let journal = try OperationJournal(directory: directory)
    let coordinator = MutationCoordinator(journal: journal)
    var count = 0
    let first = try coordinator.perform(request(), preflight: { _, _ in }, execute: {
      count += 1; return BridgeResponse(ok: true, status: "committed", batchId: "stable")
    })
    let second = try coordinator.perform(request(), preflight: { _, _ in XCTFail("replayed preflight") }, execute: {
      count += 1; return first
    })
    XCTAssertEqual(count, 1); XCTAssertEqual(second.status, "committed")
  }
  func testSameIDWithDifferentPayloadRejected() throws {
    let coordinator = MutationCoordinator(journal: try OperationJournal(directory: directory))
    _ = try coordinator.perform(request(), preflight: { _, _ in }, execute: { BridgeResponse(ok: true, status: "committed") })
    var changed = request(); changed.item?.title = "Other"
    XCTAssertThrowsError(try coordinator.perform(changed, preflight: { _, _ in }, execute: { XCTFail(); return BridgeResponse(ok: true, status: "committed") }))
  }
  func testWriteThenFailureIsUnknownAndNeverRetried() throws {
    let coordinator = MutationCoordinator(journal: try OperationJournal(directory: directory))
    var writes = 0
    let result = try coordinator.perform(request(), preflight: { _, _ in }, execute: {
      writes += 1; throw BridgeError.storage("audit disk failure after save")
    })
    XCTAssertFalse(result.ok); XCTAssertEqual(result.status, "unknown")
    _ = try coordinator.perform(request(), preflight: { _, _ in }, execute: {
      writes += 1; return BridgeResponse(ok: true, status: "committed")
    })
    XCTAssertEqual(writes, 1)
  }
  func testInterruptedExecutionSurvivesReopen() throws {
    var canonical = request(); canonical.confirmed = nil
    do {
      let journal = try OperationJournal(directory: directory)
      try journal.write("operation:stable", OperationRecord(digest: OperationJournal.digest(try OperationJournal.encode(canonical)), state: "executing"))
    }
    let coordinator = MutationCoordinator(journal: try OperationJournal(directory: directory))
    let result = try coordinator.perform(request(), preflight: { _, _ in XCTFail() }, execute: { XCTFail(); return BridgeResponse(ok: true, status: "committed") })
    XCTAssertEqual(result.status, "unknown")
  }
  func testPreflightRejectsWithoutStartingMutation() throws {
    let journal = try OperationJournal(directory: directory)
    XCTAssertThrowsError(try MutationCoordinator(journal: journal).perform(request(), preflight: { _, _ in
      throw BridgeError.confirmationRequired("new conflict")
    }, execute: { XCTFail(); return BridgeResponse(ok: true, status: "committed") }))
    XCTAssertNil(try journal.read("operation:stable", as: OperationRecord.self))
  }
  func testConcurrentJournalIsRejected() throws {
    let journal = try OperationJournal(directory: directory)
    XCTAssertThrowsError(try OperationJournal(directory: directory))
    withExtendedLifetime(journal) {}
  }
  func testPatchPreservesFieldsAndDuration() throws {
    let original = ItemDraft(kind: .event, title: "Test", start: "2030-01-01T10:00:00+08:00",
      end: "2030-01-01T11:30:00+08:00", location: "Room", notes: "Notes",
      alerts: [AlertSpec(minutesBefore: 30)], recurrence: RecurrenceSpec(frequency: "weekly"))
    let patch = try JSONDecoder().decode(ItemPatch.self, from: Data(#"{"start":"2030-01-01T12:00:00+08:00"}"#.utf8))
    let updated = try patch.applying(to: original)
    XCTAssertEqual(updated.location, original.location); XCTAssertEqual(updated.notes, original.notes)
    XCTAssertEqual(updated.alerts, original.alerts); XCTAssertEqual(updated.recurrence, original.recurrence)
    XCTAssertEqual(updated.end, "2030-01-01T13:30:00+08:00")
  }
  func testPatchExplicitClearAndAmbiguousClear() throws {
    let original = ItemDraft(kind: .event, title: "Test", start: "2030-01-01T10:00:00+08:00", notes: "Keep")
    let patch = try JSONDecoder().decode(ItemPatch.self, from: Data(#"{"clear":["notes","alerts"]}"#.utf8))
    let updated = try patch.applying(to: original)
    XCTAssertNil(updated.notes); XCTAssertEqual(updated.alerts, [])
    let invalid = try JSONDecoder().decode(ItemPatch.self, from: Data(#"{"notes":"new","clear":["notes"]}"#.utf8))
    XCTAssertThrowsError(try invalid.applying(to: original))
  }
}
