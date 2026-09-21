import Foundation

/// Tiny assert harness so the executable Checks target reads like the eventual XCTest suite.
public struct CheckRunner {
    public private(set) var failures = 0
    public private(set) var passed = 0
    public init() {}

    public mutating func check(_ condition: Bool, _ message: @autoclosure () -> String,
                              file: StaticString = #file, line: UInt = #line) {
        if condition { passed += 1 } else { failures += 1; FileHandle.standardError.write(Data("FAIL \(file):\(line): \(message())\n".utf8)) }
    }

    public mutating func expectThrows<T>(_ message: @autoclosure () -> String, _ body: () throws -> T,
                                        file: StaticString = #file, line: UInt = #line) {
        do { _ = try body(); check(false, "expected throw: \(message())", file: file, line: line) }
        catch { passed += 1 }
    }

    public func finish(_ suite: String) {
        FileHandle.standardError.write(Data("\(suite): \(passed) passed, \(failures) failed\n".utf8))
    }
}
