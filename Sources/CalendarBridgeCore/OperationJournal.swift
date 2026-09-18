import Foundation
import CryptoKit
import Darwin

/// A process lock and atomic, private records. Keep this independent of EventKit.
public final class OperationJournal {
  public let directory: URL
  private let descriptor: Int32

  public init(directory: URL) throws {
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    descriptor = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else { throw JournalError.storage("Cannot open operation lock") }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      throw JournalError.storage("busy: another operation is running; do not retry while pending")
    }
  }
  deinit { flock(descriptor, LOCK_UN); close(descriptor) }

  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
  public static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private func path(_ key: String) -> URL {
    directory.appendingPathComponent(Self.digest(Data(key.utf8)) + ".json")
  }
  public func read<T: Decodable>(_ key: String, as: T.Type) throws -> T? {
    let url = path(key)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
  }
  public func write<T: Encodable>(_ key: String, _ value: T) throws {
    let url = path(key)
    try Self.encode(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let fd = open(url.path, O_RDONLY)
    guard fd >= 0 else { throw JournalError.storage("Cannot sync record") }
    defer { close(fd) }
    guard fsync(fd) == 0 else { throw JournalError.storage("Cannot sync record") }
    let dirFD = open(directory.path, O_RDONLY)
    if dirFD >= 0 { _ = fsync(dirFD); close(dirFD) }
  }
}
public enum JournalError: Error { case storage(String) }

public struct OperationRecord: Codable {
  public var digest: String
  public var state: String
  public var response: Data?
  public var error: String?
  public init(digest: String, state: String, response: Data? = nil, error: String? = nil) {
    self.digest = digest; self.state = state; self.response = response; self.error = error
  }
}
