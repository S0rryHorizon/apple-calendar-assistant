import CalendarBridgeCore
import Foundation
import SQLite3

package struct AuditOperation {
  package let id: Int64
  let batchId: String
  let action: String
  let entityType: String
  let calendarItemId: String?
  let externalId: String?
  let beforeJSON: String?
  let afterJSON: String?
}

package final class AuditStore {
  private var db: OpaquePointer?
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  static var baseDirectory: URL {
    if let path = ProcessInfo.processInfo.environment["CALENDAR_BRIDGE_STATE_DIR"] {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CalendarBridge")
  }

  package init(directory: URL? = nil) throws {
    let manager = FileManager.default
    let base = directory ?? Self.baseDirectory
    try manager.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let path = base.appendingPathComponent("operations.sqlite").path
    guard sqlite3_open(path, &db) == SQLITE_OK else {
      throw BridgeError.storage("无法打开本地操作数据库：\(lastError)")
    }
    var statement: OpaquePointer?
    sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil)
    let version = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
    sqlite3_finalize(statement)
    if version < 2 {
      let backupPath = base.appendingPathComponent("operations-before-v2-" + UUID().uuidString + ".sqlite").path
      var destination: OpaquePointer?
      guard sqlite3_open(backupPath, &destination) == SQLITE_OK else { throw BridgeError.storage("无法创建迁移备份。") }
      defer { sqlite3_close(destination) }
      guard let backup = sqlite3_backup_init(destination, "main", db, "main") else { throw BridgeError.storage("无法初始化迁移备份。") }
      let code = sqlite3_backup_step(backup, -1); sqlite3_backup_finish(backup)
      guard code == SQLITE_DONE else { throw BridgeError.storage("迁移备份失败。") }
      try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupPath)
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
    try execute("PRAGMA user_version=2;")
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
  }

  deinit { sqlite3_close(db) }

  package func beginBatch(id: String, action: String) throws {
    let sql = "INSERT INTO batches(id, action, created_at) VALUES(?, ?, ?);"
    try withStatement(sql) { statement in
      bind(id, at: 1, in: statement)
      bind(action, at: 2, in: statement)
      bind(CalendarRules.formatDate(Date()), at: 3, in: statement)
      try stepDone(statement)
    }
  }

  package func record(
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

  package func operations(for batchId: String) throws -> [AuditOperation] {
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

  package func markRolledBack(_ batchId: String) throws {
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
