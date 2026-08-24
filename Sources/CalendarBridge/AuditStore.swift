import CalendarBridgeCore
import Foundation
import SQLite3

struct AuditOperation {
  let id: Int64
  let batchId: String
  let action: String
  let entityType: String
  let calendarItemId: String?
  let externalId: String?
  let beforeJSON: String?
  let afterJSON: String?
}

final class AuditStore {
  private var db: OpaquePointer?
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init() throws {
    let manager = FileManager.default
    let base = try manager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appendingPathComponent("CalendarBridge", isDirectory: true)
    try manager.createDirectory(at: base, withIntermediateDirectories: true)
    let path = base.appendingPathComponent("operations.sqlite").path
    guard sqlite3_open(path, &db) == SQLITE_OK else {
      throw BridgeError.storage("无法打开本地操作数据库：\(lastError)")
    }
    try execute("PRAGMA journal_mode=WAL;")
    try execute("PRAGMA foreign_keys=ON;")
    try execute(
      """
      CREATE TABLE IF NOT EXISTS batches (
          id TEXT PRIMARY KEY,
          action TEXT NOT NULL,
          created_at TEXT NOT NULL,
          rolled_back INTEGER NOT NULL DEFAULT 0
      );
      """)
    try execute(
      """
      CREATE TABLE IF NOT EXISTS operations (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          batch_id TEXT NOT NULL REFERENCES batches(id),
          action TEXT NOT NULL,
          entity_type TEXT NOT NULL,
          calendar_item_id TEXT,
          external_id TEXT,
          before_json TEXT,
          after_json TEXT,
          created_at TEXT NOT NULL
      );
      """)
  }

  deinit { sqlite3_close(db) }

  func beginBatch(id: String, action: String) throws {
    let sql = "INSERT OR IGNORE INTO batches(id, action, created_at) VALUES(?, ?, ?);"
    try withStatement(sql) { statement in
      bind(id, at: 1, in: statement)
      bind(action, at: 2, in: statement)
      bind(CalendarRules.formatDate(Date()), at: 3, in: statement)
      try stepDone(statement)
    }
  }

  func record(
    batchId: String,
    action: String,
    entityType: ItemKind,
    calendarItemId: String?,
    externalId: String?,
    before: ItemSnapshot?,
    after: ItemSnapshot?
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    func encoded(_ value: ItemSnapshot?) throws -> String? {
      guard let value else { return nil }
      return String(data: try encoder.encode(value), encoding: .utf8)
    }
    let sql = """
      INSERT INTO operations(
          batch_id, action, entity_type, calendar_item_id, external_id,
          before_json, after_json, created_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?);
      """
    try withStatement(sql) { statement in
      bind(batchId, at: 1, in: statement)
      bind(action, at: 2, in: statement)
      bind(entityType.rawValue, at: 3, in: statement)
      bind(calendarItemId, at: 4, in: statement)
      bind(externalId, at: 5, in: statement)
      bind(try encoded(before), at: 6, in: statement)
      bind(try encoded(after), at: 7, in: statement)
      bind(CalendarRules.formatDate(Date()), at: 8, in: statement)
      try stepDone(statement)
    }
  }

  func operations(for batchId: String) throws -> [AuditOperation] {
    let sql = """
      SELECT o.id, o.batch_id, o.action, o.entity_type, o.calendar_item_id,
             o.external_id, o.before_json, o.after_json
      FROM operations o JOIN batches b ON b.id = o.batch_id
      WHERE o.batch_id = ? AND b.rolled_back = 0
      ORDER BY o.id DESC;
      """
    return try withStatement(sql) { statement in
      bind(batchId, at: 1, in: statement)
      var result: [AuditOperation] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        result.append(
          AuditOperation(
            id: sqlite3_column_int64(statement, 0),
            batchId: text(statement, 1) ?? batchId,
            action: text(statement, 2) ?? "",
            entityType: text(statement, 3) ?? "",
            calendarItemId: text(statement, 4),
            externalId: text(statement, 5),
            beforeJSON: text(statement, 6),
            afterJSON: text(statement, 7)
          ))
      }
      return result
    }
  }

  func markRolledBack(_ batchId: String) throws {
    try withStatement("UPDATE batches SET rolled_back = 1 WHERE id = ?;") { statement in
      bind(batchId, at: 1, in: statement)
      try stepDone(statement)
      guard sqlite3_changes(db) > 0 else {
        throw BridgeError.notFound("找不到可回滚批次：\(batchId)")
      }
    }
  }

  private func execute(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw BridgeError.storage(lastError)
    }
  }

  private func withStatement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw BridgeError.storage(lastError)
    }
    defer { sqlite3_finalize(statement) }
    return try body(statement)
  }

  private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
    if let value {
      sqlite3_bind_text(statement, index, value, -1, transient)
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  private func stepDone(_ statement: OpaquePointer) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw BridgeError.storage(lastError)
    }
  }

  private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard let pointer = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: pointer)
  }

  private var lastError: String {
    guard let db, let pointer = sqlite3_errmsg(db) else { return "未知 SQLite 错误" }
    return String(cString: pointer)
  }
}
