import XCTest
@testable import CCUsageStats

final class ClaudeCodeKeychainProbeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_000_000) // 2026-07-25 18:40 UTC

    // MARK: - Payload builders

    private func claudeAiOauth(token: String, expiresAt: Date, withMCP: Bool = true) -> String {
        var obj: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": token,
                "refreshToken": "sk-ant-ort01-refresh",
                "expiresAt": Int(expiresAt.timeIntervalSince1970 * 1000),
                "scopes": ["user:inference"],
                "subscriptionType": "max",
            ] as [String: Any],
        ]
        if withMCP { obj["mcpOAuth"] = ["plugin:foo|abc": ["accessToken": "mcp-token"]] }
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private var mcpOnlyPayload: String {
        let obj: [String: Any] = [
            "mcpOAuth": [
                "plugin:finance:bigquery|7725a4f9": ["accessToken": "mcp-token-1"],
                "plugin:product-management:asana|71ef7e5a": ["accessToken": "mcp-token-2"],
            ],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private func entry(_ service: String, _ daysAgo: Double, _ payload: String) -> ClaudeCodeKeychainProbe.Entry {
        ClaudeCodeKeychainProbe.Entry(
            service: service,
            modified: now.addingTimeInterval(-daysAgo * 86_400),
            payload: payload
        )
    }

    // MARK: - Suffixed-service discovery

    func testFindsTokenInSuffixedServiceWhenBareServiceIsMCPOnly() {
        let entries = [
            entry("Claude Code-credentials", 3, mcpOnlyPayload),
            entry("Claude Code-credentials-0a53e818", 1,
                  claudeAiOauth(token: "sk-ant-oat01-fromsuffixed", expiresAt: now.addingTimeInterval(3600))),
        ]
        XCTAssertEqual(ClaudeCodeKeychainProbe.selectToken(from: entries, now: now), "sk-ant-oat01-fromsuffixed")
    }

    func testPrefersNewestEntryAmongMultipleUsableTokens() {
        let entries = [
            entry("Claude Code-credentials-98915f0c", 14,
                  claudeAiOauth(token: "sk-ant-oat01-older", expiresAt: now.addingTimeInterval(3600))),
            entry("Claude Code-credentials-0a53e818", 1,
                  claudeAiOauth(token: "sk-ant-oat01-newer", expiresAt: now.addingTimeInterval(3600))),
            entry("Claude Code-credentials", 7,
                  claudeAiOauth(token: "sk-ant-oat01-middle", expiresAt: now.addingTimeInterval(3600))),
        ]
        XCTAssertEqual(ClaudeCodeKeychainProbe.selectToken(from: entries, now: now), "sk-ant-oat01-newer")
    }

    // MARK: - Expiry rejection

    func testRejectsExpiredToken() {
        let entries = [
            entry("Claude Code-credentials", 3,
                  claudeAiOauth(token: "sk-ant-oat01-expired", expiresAt: now.addingTimeInterval(-3600))),
        ]
        XCTAssertNil(ClaudeCodeKeychainProbe.selectToken(from: entries, now: now))
    }

    func testFallsBackToOlderUnexpiredEntryWhenNewestIsExpired() {
        let entries = [
            entry("Claude Code-credentials-0a53e818", 1,
                  claudeAiOauth(token: "sk-ant-oat01-expired", expiresAt: now.addingTimeInterval(-60))),
            entry("Claude Code-credentials", 7,
                  claudeAiOauth(token: "sk-ant-oat01-stillvalid", expiresAt: now.addingTimeInterval(3600))),
        ]
        XCTAssertEqual(ClaudeCodeKeychainProbe.selectToken(from: entries, now: now), "sk-ant-oat01-stillvalid")
    }

    /// Reproduces this machine's 2026-07-27 state: bare entry holds a token that
    /// expired 2026-07-25, both suffixed entries hold only `mcpOAuth`.
    func testRealWorldLegacyStateYieldsNoToken() {
        let entries = [
            entry("Claude Code-credentials", 3,
                  claudeAiOauth(token: "sk-ant-oat01-stale", expiresAt: now.addingTimeInterval(-2 * 86_400))),
            entry("Claude Code-credentials-98915f0c", 14, mcpOnlyPayload),
            entry("Claude Code-credentials-0a53e818", 0, mcpOnlyPayload),
        ]
        XCTAssertNil(ClaudeCodeKeychainProbe.selectToken(from: entries, now: now))
    }

    // MARK: - mcpOAuth-only entries are skipped

    func testSkipsMCPOAuthOnlyEntries() {
        let entries = [
            entry("Claude Code-credentials-98915f0c", 14, mcpOnlyPayload),
            entry("Claude Code-credentials-0a53e818", 0, mcpOnlyPayload),
        ]
        XCTAssertNil(ClaudeCodeKeychainProbe.selectToken(from: entries, now: now))
    }

    func testMCPOAuthOnlyNewestDoesNotShadowOlderUsableToken() {
        let entries = [
            entry("Claude Code-credentials-0a53e818", 0, mcpOnlyPayload),
            entry("Claude Code-credentials", 7,
                  claudeAiOauth(token: "sk-ant-oat01-good", expiresAt: now.addingTimeInterval(3600))),
        ]
        XCTAssertEqual(ClaudeCodeKeychainProbe.selectToken(from: entries, now: now), "sk-ant-oat01-good")
    }

    // MARK: - Token shape

    func testRejectsAPIKeyShapedAccessToken() {
        let entries = [
            entry("Claude Code-credentials", 1,
                  claudeAiOauth(token: "sk-ant-api03-notanoauthtoken", expiresAt: now.addingTimeInterval(3600))),
        ]
        XCTAssertNil(ClaudeCodeKeychainProbe.selectToken(from: entries, now: now))
    }

    func testAcceptsBareTokenPayload() {
        let entries = [entry("Claude Code-credentials", 1, "sk-ant-oat01-baretoken")]
        XCTAssertEqual(ClaudeCodeKeychainProbe.selectToken(from: entries, now: now), "sk-ant-oat01-baretoken")
    }

    func testAcceptsEntryWithoutExpiresAt() {
        let obj: [String: Any] = ["claudeAiOauth": ["accessToken": "sk-ant-oat01-noexpiry"]]
        let payload = String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        XCTAssertEqual(
            ClaudeCodeKeychainProbe.selectToken(from: [entry("Claude Code-credentials", 1, payload)], now: now),
            "sk-ant-oat01-noexpiry"
        )
    }

    func testIgnoresGarbagePayload() {
        let entries = [entry("Claude Code-credentials", 1, "not json at all")]
        XCTAssertNil(ClaudeCodeKeychainProbe.selectToken(from: entries, now: now))
    }

    func testEmptyEntryListReturnsNil() {
        XCTAssertNil(ClaudeCodeKeychainProbe.selectToken(from: [], now: now))
    }

    // MARK: - Payload resolution is fetched once per candidate

    /// Each payload fetch triggers a macOS Keychain access prompt in the shipping
    /// caller, so the winning candidate must not be resolved twice.
    func testResolvesWinningCandidatePayloadExactlyOnce() {
        var fetched: [String] = []
        let token = ClaudeCodeKeychainProbe.firstUsableToken(
            candidates: ["mcp-only", "valid", "never-reached"],
            now: now
        ) { name in
            fetched.append(name)
            switch name {
            case "mcp-only": return self.mcpOnlyPayload
            case "valid": return self.claudeAiOauth(token: "sk-ant-oat01-once",
                                                    expiresAt: self.now.addingTimeInterval(3600))
            default: return "sk-ant-oat01-shouldnotbereached"
            }
        }
        XCTAssertEqual(token, "sk-ant-oat01-once")
        XCTAssertEqual(fetched, ["mcp-only", "valid"])
    }

    /// A payload fetch that succeeds once and is then denied must not trap.
    /// (Lazy `compactMap` + `Collection.first` re-evaluates the winner and
    /// force-unwraps the second, nil result.)
    func testDeniedSecondFetchOfWinnerDoesNotTrap() {
        var attempts = 0
        let token = ClaudeCodeKeychainProbe.firstUsableToken(
            candidates: ["only"],
            now: now
        ) { _ in
            attempts += 1
            return attempts == 1
                ? self.claudeAiOauth(token: "sk-ant-oat01-allowed", expiresAt: self.now.addingTimeInterval(3600))
                : nil // user denied the repeat prompt
        }
        XCTAssertEqual(token, "sk-ant-oat01-allowed")
        XCTAssertEqual(attempts, 1)
    }

    // MARK: - Expiry parsing

    func testRejectsExpiredTokenWhenExpiresAtIsAString() {
        let expired = Int(now.addingTimeInterval(-86_400).timeIntervalSince1970 * 1000)
        let obj: [String: Any] = [
            "claudeAiOauth": ["accessToken": "sk-ant-oat01-stringexpiry", "expiresAt": "\(expired)"],
        ]
        let payload = String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        XCTAssertNil(
            ClaudeCodeKeychainProbe.selectToken(from: [entry("Claude Code-credentials", 1, payload)], now: now)
        )
    }
}
