import Foundation

final class CheckResults {
    static let shared = CheckResults()
    private let lock = NSLock()
    private(set) var failures = 0
    private(set) var assertions = 0

    func record(_ passed: Bool, _ message: String, file: StaticString, line: UInt) {
        lock.lock()
        defer { lock.unlock() }
        assertions += 1
        if !passed {
            failures += 1
            print("FAIL \(file):\(line) \(message)")
        }
    }
}

func expectEqual<Value: Equatable>(_ actual: Value, _ expected: Value, _ message: String = "",
                                   file: StaticString = #filePath, line: UInt = #line) {
    CheckResults.shared.record(actual == expected, "Expected equality. \(message)", file: file, line: line)
}

func expectNotEqual<Value: Equatable>(_ actual: Value, _ expected: Value,
                                      file: StaticString = #filePath, line: UInt = #line) {
    CheckResults.shared.record(actual != expected, "Expected distinct values", file: file, line: line)
}

func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    CheckResults.shared.record(value, "Expected true", file: file, line: line)
}

func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    CheckResults.shared.record(!value, "Expected false", file: file, line: line)
}

func expectNil<Value>(_ value: Value?, file: StaticString = #filePath, line: UInt = #line) {
    CheckResults.shared.record(value == nil, "Expected nil", file: file, line: line)
}

func requireValue<Value>(_ value: Value?, file: StaticString = #filePath, line: UInt = #line) throws -> Value {
    guard let value else { throw NSError(domain: "ClipDune.Checks.MissingValue", code: 1) }
    return value
}

func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    CheckResults.shared.record(false, message, file: file, line: line)
}
