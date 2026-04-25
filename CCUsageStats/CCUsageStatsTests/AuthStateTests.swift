import XCTest
@testable import CCUsageStats

final class AuthStateTests: XCTestCase {
    func testAllCasesExist() {
        let all: [AuthState] = [.unknown, .ok, .invalidToken, .notSubscriber, .offline]
        XCTAssertEqual(Set(all).count, 5)
    }
    func testEquatable() {
        XCTAssertEqual(AuthState.ok, AuthState.ok)
        XCTAssertNotEqual(AuthState.ok, AuthState.offline)
    }
}
