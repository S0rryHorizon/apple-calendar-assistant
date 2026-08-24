import CalendarBridgeCore
import Foundation

private func inputData() throws -> Data {
  let arguments = CommandLine.arguments
  if arguments.count == 3, arguments[1] == "--request" {
    return try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
  }
  if arguments.count == 2, arguments[1] == "--help" {
    let help = """
      CalendarBridge — JSON stdin/stdout interface

      Usage:
        echo '{"action":"status"}' | CalendarBridge
        CalendarBridge --request request.json

      Actions: setup, status, event.list/create/update/delete,
      reminder.list/create/update/delete/complete, batch.preview/commit/rollback
      """
    FileHandle.standardOutput.write(Data(help.utf8))
    exit(0)
  }
  let data = FileHandle.standardInput.readDataToEndOfFile()
  guard !data.isEmpty else { throw BridgeError.invalidRequest("请通过 stdin 或 --request 提供 JSON。") }
  return data
}

private func emit(_ response: BridgeResponse) {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  if let data = try? encoder.encode(response) {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
}

do {
  let data = try inputData()
  let request = try JSONDecoder().decode(BridgeRequest.self, from: data)
  let service = try EventKitService()
  emit(try service.handle(request))
} catch {
  emit(BridgeResponse(ok: false, status: "error", message: String(describing: error)))
  exit(1)
}
