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

    // MARK: - Expiry surfaces to the caller

    /// The bug this work fixes: the probe used to parse `expiresAt` only to
    /// reject stale entries, then throw it away, so nothing downstream could
    /// tell a short-lived import from a durable paste.
    func testSurfacesMillisecondExpiryAlongsideToken() {
        let expiry = now.addingTimeInterval(8 * 3600) // observed real-world lifetime
        let entries = [entry("Claude Code-credentials", 1,
                             claudeAiOauth(token: "sk-ant-oat01-short", expiresAt: expiry))]
        XCTAssertEqual(
            ClaudeCodeKeychainProbe.selectImport(from: entries, now: now),
            ClaudeCodeKeychainProbe.ImportedToken(token: "sk-ant-oat01-short", expiresAt: expiry)
        )
    }

    /// `expiresAt` below the millisecond threshold is read as seconds — the same
    /// tolerance the rejection path already applies.
    func testSurfacesSecondsExpiry() {
        let expiry = now.addingTimeInterval(3600)
        let obj: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "sk-ant-oat01-seconds",
                "expiresAt": Int(expiry.timeIntervalSince1970),
            ],
        ]
        let payload = String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        XCTAssertEqual(
            ClaudeCodeKeychainProbe.selectImport(from: [entry("Claude Code-credentials", 1, payload)], now: now),
            ClaudeCodeKeychainProbe.ImportedToken(token: "sk-ant-oat01-seconds", expiresAt: expiry)
        )
    }

    func testSurfacesStringEncodedExpiry() {
        let expiry = now.addingTimeInterval(2 * 3600)
        let obj: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "sk-ant-oat01-stringexp",
                "expiresAt": "\(Int(expiry.timeIntervalSince1970 * 1000))",
            ],
        ]
        let payload = String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        XCTAssertEqual(
            ClaudeCodeKeychainProbe.selectImport(from: [entry("Claude Code-credentials", 1, payload)], now: now),
            ClaudeCodeKeychainProbe.ImportedToken(token: "sk-ant-oat01-stringexp", expiresAt: expiry)
        )
    }

    func testEnvelopeWithoutExpiresAtSurfacesNilExpiry() {
        let obj: [String: Any] = ["claudeAiOauth": ["accessToken": "sk-ant-oat01-noexpiry"]]
        let payload = String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        XCTAssertEqual(
            ClaudeCodeKeychainProbe.selectImport(from: [entry("Claude Code-credentials", 1, payload)], now: now),
            ClaudeCodeKeychainProbe.ImportedToken(token: "sk-ant-oat01-noexpiry", expiresAt: nil)
        )
    }

    func testBareTokenPayloadSurfacesNilExpiry() {
        XCTAssertEqual(
            ClaudeCodeKeychainProbe.selectImport(
                from: [entry("Claude Code-credentials", 1, "sk-ant-oat01-baretoken")], now: now
            ),
            ClaudeCodeKeychainProbe.ImportedToken(token: "sk-ant-oat01-baretoken", expiresAt: nil)
        )
    }

    /// Skipping past an expired newest entry must carry the *winner's* deadline,
    /// not the rejected one's.
    func testSurfacedExpiryBelongsToTheWinningEntry() {
        let winnerExpiry = now.addingTimeInterval(3600)
        let entries = [
            entry("Claude Code-credentials-0a53e818", 1,
                  claudeAiOauth(token: "sk-ant-oat01-expired", expiresAt: now.addingTimeInterval(-60))),
            entry("Claude Code-credentials", 7,
                  claudeAiOauth(token: "sk-ant-oat01-stillvalid", expiresAt: winnerExpiry)),
        ]
        XCTAssertEqual(
            ClaudeCodeKeychainProbe.selectImport(from: entries, now: now),
            ClaudeCodeKeychainProbe.ImportedToken(token: "sk-ant-oat01-stillvalid", expiresAt: winnerExpiry)
        )
    }

    // MARK: - Miss classification

    /// This machine's actual failure on 2026-07-31: the CLI's token lapsed
    /// overnight and nothing had rotated it since.
    func testAllEntriesExpiredReportsTheDeadline() {
        let deadline = now.addingTimeInterval(-(13 * 3600))
        let entries = [
            entry("Claude Code-credentials", 1, claudeAiOauth(token: "sk-ant-oat01-stale", expiresAt: deadline)),
            entry("Claude Code-credentials-0a53e818", 3, mcpOnlyPayload),
        ]
        XCTAssertEqual(ClaudeCodeKeychainProbe.classifyEntries(entries, now: now), .expired(deadline))
    }

    /// Newest-first ordering usually surfaces the latest deadline first, but an
    /// older item can carry a later one — the message should quote the freshest.
    func testExpiredReportsTheLatestDeadlineSeen() {
        let older = now.addingTimeInterval(-8 * 3600)
        let later = now.addingTimeInterval(-1 * 3600)
        let entries = [
            entry("Claude Code-credentials-0a53e818", 0, claudeAiOauth(token: "sk-ant-oat01-a", expiresAt: older)),
            entry("Claude Code-credentials", 5, claudeAiOauth(token: "sk-ant-oat01-b", expiresAt: later)),
        ]
        XCTAssertEqual(ClaudeCodeKeychainProbe.classifyEntries(entries, now: now), .expired(later))
    }

    func testMCPOnlyEntriesReportNoClaudeToken() {
        let entries = [
            entry("Claude Code-credentials-98915f0c", 14, mcpOnlyPayload),
            entry("Claude Code-credentials-0a53e818", 0, mcpOnlyPayload),
        ]
        XCTAssertEqual(ClaudeCodeKeychainProbe.classifyEntries(entries, now: now), .noClaudeToken)
    }

    func testNoEntriesIsDistinctFromUnusableEntries() {
        XCTAssertEqual(ClaudeCodeKeychainProbe.classifyEntries([], now: now), .noEntries)
    }

    /// A denied prompt must never read as "nothing there" — the item may well
    /// hold a good token we simply weren't allowed to see.
    func testDeniedFetchReportsAccessDenied() {
        let outcome = ClaudeCodeKeychainProbe.classify(candidates: ["locked"], now: now) { _ in .denied }
        XCTAssertEqual(outcome, .accessDenied)
    }

    /// Denial outranks expiry: reporting "expired" would send the user to the
    /// CLI when the real fix is clicking Allow.
    func testDenialOutranksExpiry() {
        let outcome = ClaudeCodeKeychainProbe.classify(
            candidates: ["locked", "stale"], now: now
        ) { name in
            name == "locked"
                ? .denied
                : .body(self.claudeAiOauth(token: "sk-ant-oat01-stale",
                                           expiresAt: self.now.addingTimeInterval(-3600)))
        }
        XCTAssertEqual(outcome, .accessDenied)
    }

    /// A usable token still wins over a denial encountered earlier in the sweep.
    func testUsableTokenWinsDespiteAnEarlierDenial() {
        let outcome = ClaudeCodeKeychainProbe.classify(
            candidates: ["locked", "good"], now: now
        ) { name in
            name == "locked"
                ? .denied
                : .body(self.claudeAiOauth(token: "sk-ant-oat01-good",
                                           expiresAt: self.now.addingTimeInterval(3600)))
        }
        XCTAssertEqual(
            outcome,
            .found(ClaudeCodeKeychainProbe.ImportedToken(token: "sk-ant-oat01-good",
                                                         expiresAt: now.addingTimeInterval(3600)))
        )
    }

    /// An item that disappeared between the attribute query and the data read is
    /// absent, not denied.
    func testAbsentFetchIsNotADenial() {
        let outcome = ClaudeCodeKeychainProbe.classify(candidates: ["vanished"], now: now) { _ in .absent }
        XCTAssertEqual(outcome, .noEntries)
    }

    /// An expired API key is "no claude.ai token", not "your token expired" —
    /// adopting it was never possible, so the expiry is not the story.
    func testExpiredAPIKeyShapedTokenIsUnusableNotExpired() {
        let entries = [
            entry("Claude Code-credentials", 1,
                  claudeAiOauth(token: "sk-ant-api03-notanoauthtoken", expiresAt: now.addingTimeInterval(-3600))),
        ]
        XCTAssertEqual(ClaudeCodeKeychainProbe.classifyEntries(entries, now: now), .noClaudeToken)
    }

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
