import Foundation

/// Testable write boundary; backend effects only run after durable intent and preflight.
public struct MutationCoordinator {
  public let journal: OperationJournal
  public init(journal: OperationJournal) { self.journal = journal }
  public func perform(_ request: BridgeRequest,
    preflight: (String, String) throws -> Void,
    execute: () throws -> BridgeResponse) throws -> BridgeResponse {
    guard let id = request.batchId, !id.isEmpty else {
      throw BridgeError.invalidRequest("protocol_upgrade_required: 写入需要稳定 batchId；请更新 skill。")
    }
    var canonical = request; canonical.requestId = nil; canonical.confirmed = nil; canonical.dryRun = nil
    let digest = OperationJournal.digest(try OperationJournal.encode(canonical))
    let key = "operation:" + (request.action == "batch.rollback" ? "rollback:" : "") + id
    if let previous = try journal.read(key, as: OperationRecord.self) {
      guard previous.digest == digest else { throw BridgeError.invalidRequest("同一 batchId 不能用于不同内容。") }
      if !["preview", "needs_confirmation"].contains(previous.state) {
        if let data = previous.response { return try JSONDecoder().decode(BridgeResponse.self, from: data) }
        return BridgeResponse(ok: false, status: "unknown", message: previous.error ?? "上次执行结果待核查，未再次写入。", batchId: id)
      }
    }
    try preflight(id, digest)
    try journal.write("request:" + key, canonical)
    try journal.write(key, OperationRecord(digest: digest, state: "executing"))
    do {
      let response = try execute()
      try journal.write(key, OperationRecord(digest: digest, state: response.status,
        response: try OperationJournal.encode(response)))
      return response
    } catch {
      let response = BridgeResponse(ok: false, status: "unknown", message: String(describing: error),
        batchId: id, details: ["nextAction": "核查已记录的操作与实际事项；不要重新提交"])
      try journal.write(key, OperationRecord(digest: digest, state: "unknown",
        response: try OperationJournal.encode(response), error: String(describing: error)))
      return response
    }
  }

}
