import Foundation

final class TestResults: @unchecked Sendable {
  static let shared = TestResults()
  var failures = 0
}
class TestCase {
  func setUpWithError() throws {}
  func tearDownWithError() throws {}
}
func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
  TestResults.shared.failures += 1
  print("FAIL: \(file):\(line) \(message)")
}
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
  do { if try !value() { XCTFail("expected true", file: file, line: line) } }
  catch { XCTFail(String(describing: error), file: file, line: line) }
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
  do { if try value() { XCTFail("expected false", file: file, line: line) } }
  catch { XCTFail(String(describing: error), file: file, line: line) }
}
func XCTAssertEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
  do { let a = try left(), b = try right(); if a != b { XCTFail("\(a) != \(b)", file: file, line: line) } }
  catch { XCTFail(String(describing: error), file: file, line: line) }
}
func XCTAssertNotEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
  do { if try left() == right() { XCTFail("expected different values", file: file, line: line) } }
  catch { XCTFail(String(describing: error), file: file, line: line) }
}
func XCTAssertNil<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) {
  do { if try value() != nil { XCTFail("expected nil", file: file, line: line) } }
  catch { XCTFail(String(describing: error), file: file, line: line) }
}
func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
  do { _ = try value(); XCTFail("expected error", file: file, line: line) } catch {}
}
func run(_ tests: TestCase, name: String, body: () throws -> Void) {
  do { try tests.setUpWithError(); try body() }
  catch { XCTFail("\(name): \(error)") }
  do { try tests.tearDownWithError() } catch { XCTFail("teardown: \(error)") }
}
