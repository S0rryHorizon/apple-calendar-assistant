import Foundation

public enum InstallationDiagnostics {
  public static func read(support: String) throws -> [String: String] {
    let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/" + support)
    let path = base.appendingPathComponent("installation.json")
    var result = ["protocolVersion": "2", "bridgeVersion": "2.0.0-experimental", "permissionProbe": "not_requested"]
    guard FileManager.default.fileExists(atPath: path.path) else {
      result["installation"] = "unmanaged_or_legacy"; return result
    }
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any],
      let hashes = object["files"] as? [String: String] else {
      throw JournalError.storage("Invalid installation manifest")
    }
    var changed: [String] = []
    for (file, hash) in hashes {
      if let data = try? Data(contentsOf: URL(fileURLWithPath: file)), OperationJournal.digest(data) == hash { continue }
      changed.append(file)
    }
    result["installation"] = changed.isEmpty ? "verified" : "drift"
    result["changedFiles"] = changed.sorted().joined(separator: "\n")
    result["manifestVersion"] = String(describing: object["protocolVersion"] ?? "missing")
    result["pendingInstallation"] = String(FileManager.default.fileExists(atPath: base.appendingPathComponent("install-transaction.json").path))
    return result
  }
}
