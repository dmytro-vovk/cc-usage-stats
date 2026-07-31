import XCTest
@testable import CCUsageStats

@MainActor
final class AuthStateTests: XCTestCase {
    /// Enumerates `allCases`, so adding a state without deciding how it behaves
    /// below trips this file instead of sailing through.
    func testAllCasesExist() {
        XCTAssertEqual(Set(AuthState.allCases).count, AuthState.allCases.count)
        XCTAssertEqual(AuthState.allCases.count, 6, "new AuthState case — update lacksWorkingToken coverage too")
    }
    func testEquatable() {
        XCTAssertEqual(AuthState.ok, AuthState.ok)
        XCTAssertNotEqual(AuthState.ok, AuthState.offline)
    }

    /// "Nothing stored" and "the API said no" are different facts about the
    /// world, and the dropdown says different things about them.
    func testNoTokenIsNotInvalidToken() {
        XCTAssertNotEqual(AuthState.noToken, AuthState.invalidToken)
    }

    func testOnlyTheTokenlessStatesLackAWorkingToken() {
        let lacking = AuthState.allCases.filter(\.lacksWorkingToken)
        XCTAssertEqual(Set(lacking), Set([.noToken, .invalidToken]))
    }
}
