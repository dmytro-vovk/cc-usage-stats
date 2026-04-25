import XCTest
@testable import CCUsageStats

final class WrappedCommandTests: XCTestCase {
    func testCapturesStdout() throws {
        let out = WrappedCommand.run(command: "cat", stdin: Data("hello\n".utf8), timeout: 2.0)
        XCTAssertEqual(out, "hello\n")
    }

    func testNonZeroExitReturnsCapturedStdout() throws {
        let out = WrappedCommand.run(command: "printf 'partial' && exit 3", stdin: Data(), timeout: 2.0)
        XCTAssertEqual(out, "partial")
    }

    func testTimeoutReturnsWhatWasCaptured() throws {
        let out = WrappedCommand.run(
            command: "printf 'first'; sleep 5; printf 'never'",
            stdin: Data(),
            timeout: 0.5
        )
        XCTAssertEqual(out, "first")
    }

    func testEmptyCommandReturnsEmpty() throws {
        XCTAssertEqual(WrappedCommand.run(command: "", stdin: Data(), timeout: 2.0), "")
    }
}
