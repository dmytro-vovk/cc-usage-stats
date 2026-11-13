import XCTest
@testable import CCUsageStats

final class PillComposerTests: XCTestCase {
    private let claude = [PillSegment(kind: .fiveHour, fraction: 0.56, text: "56%")]
    private func codex(_ pct: Double, resetsAt: Int64 = 1_000) -> CodexSnapshot {
        CodexSnapshot(windows: [CodexWindow(usedPercent: pct, windowMinutes: 10080, resetsAt: resetsAt)],
                      planType: nil, observedAt: 0, source: .sessionLog)
    }

    private func plan(_ mode: PillMode, tracking: Bool = true, codex: CodexSnapshot?,
                      claude: [PillSegment]? = nil, lacksToken: Bool = false, now: Int64 = 0) -> PillPlan {
        PillComposer.plan(mode: mode, codexTracking: tracking, claudeSegments: claude ?? self.claude,
                          claudeLacksWorkingToken: lacksToken, codex: codex, now: now)
    }

    func testClaudeModeIsUnchanged() {
        XCTAssertEqual(plan(.claude, codex: codex(22)), .claude)
    }

    func testTrackingOffAlwaysFallsBackToClaude() {
        XCTAssertEqual(plan(.codex, tracking: false, codex: codex(22)), .claude)
        XCTAssertEqual(plan(.both, tracking: false, codex: codex(22)), .claude)
    }

    func testCodexModeShowsOneCodexBand() {
        XCTAssertEqual(plan(.codex, codex: codex(25)),
                       .segments([PillSegment(kind: .codex, fraction: 0.25, text: "25%")]))
    }

    func testCodexModeWithoutDataShowsDimmedPlaceholder() {
        XCTAssertEqual(plan(.codex, codex: nil),
                       .segments([PillSegment(kind: .codex, fraction: 0, text: "—", dimmed: true)]))
    }

    func testCodexBandUsesResetRule() {
        XCTAssertEqual(plan(.codex, codex: codex(80, resetsAt: 10), now: 11),
                       .segments([PillSegment(kind: .codex, fraction: 0, text: "0%")]))
    }

    func testBothAppendsCodexToClaudeSegments() {
        XCTAssertEqual(plan(.both, codex: codex(22)),
                       .segments(claude + [PillSegment(kind: .codex, fraction: 0.22, text: "22%")]))
    }

    func testBothWithoutCodexDataIsClaudeOnly() {
        XCTAssertEqual(plan(.both, codex: nil), .claude)
    }

    func testBothKeepsClaudeTokenProblemVisible() {
        XCTAssertEqual(plan(.both, codex: codex(22), lacksToken: true), .claude)
    }

    func testBothWithoutClaudeDataShowsCodexOnly() {
        XCTAssertEqual(plan(.both, codex: codex(22), claude: []),
                       .segments([PillSegment(kind: .codex, fraction: 0.22, text: "22%")]))
    }

    // MARK: Gemini band

    private func gemini(_ pct: Double, resetsAt: Int64 = 1_000) -> GeminiSnapshot {
        GeminiSnapshot(buckets: [
            GeminiBucket(id: "gemini-weekly", group: "Gemini Models", window: "weekly", usedPercent: pct, resetsAt: resetsAt),
            GeminiBucket(id: "3p-weekly", group: "Claude and GPT models", window: "weekly", usedPercent: 0, resetsAt: resetsAt),
        ], observedAt: 0)
    }

    private func planG(_ mode: PillMode, tracking: Bool = true, codex: CodexSnapshot? = nil,
                       gemini: GeminiSnapshot?, band: Bool = true,
                       claude: [PillSegment]? = nil, lacksToken: Bool = false, now: Int64 = 0) -> PillPlan {
        PillComposer.plan(mode: mode, codexTracking: tracking, claudeSegments: claude ?? self.claude,
                          claudeLacksWorkingToken: lacksToken, codex: codex,
                          gemini: gemini, geminiBand: band, now: now)
    }

    private func gem(_ pct: Int) -> PillSegment {
        PillSegment(kind: .gemini, fraction: Double(pct) / 100, text: "\(pct)%")
    }

    func testGeminiBandOffChangesNothing() {
        XCTAssertEqual(planG(.claude, gemini: gemini(40), band: false), .claude)
        XCTAssertEqual(planG(.both, codex: codex(22), gemini: gemini(40), band: false),
                       .segments(claude + [PillSegment(kind: .codex, fraction: 0.22, text: "22%")]))
    }

    func testGeminiBandJoinsTheClaudePill() {
        XCTAssertEqual(planG(.claude, gemini: gemini(40)), .segments(claude + [gem(40)]))
        // Codex tracking off still lets Gemini join Claude.
        XCTAssertEqual(planG(.both, tracking: false, gemini: gemini(40)), .segments(claude + [gem(40)]))
    }

    func testGeminiBandFollowsCodex() {
        XCTAssertEqual(planG(.codex, codex: codex(25), gemini: gemini(40)),
                       .segments([PillSegment(kind: .codex, fraction: 0.25, text: "25%"), gem(40)]))
        XCTAssertEqual(planG(.both, codex: codex(22), gemini: gemini(40)),
                       .segments(claude + [PillSegment(kind: .codex, fraction: 0.22, text: "22%"), gem(40)]))
        XCTAssertEqual(planG(.both, codex: nil, gemini: gemini(40)), .segments(claude + [gem(40)]))
    }

    func testGeminiBandNeverHidesAClaudeProblem() {
        XCTAssertEqual(planG(.claude, gemini: gemini(40), lacksToken: true), .claude)
        XCTAssertEqual(planG(.both, codex: codex(22), gemini: gemini(40), lacksToken: true), .claude)
        XCTAssertEqual(planG(.claude, gemini: gemini(40), claude: []), .claude, "no Claude reading: Claude's own rendering")
    }

    func testGeminiBandWithoutDataIsLeftOut() {
        XCTAssertEqual(planG(.claude, gemini: nil), .claude)
        XCTAssertEqual(planG(.codex, codex: codex(25), gemini: nil),
                       .segments([PillSegment(kind: .codex, fraction: 0.25, text: "25%")]))
    }

    func testGeminiBandUsesTheResetRule() {
        XCTAssertEqual(planG(.claude, gemini: gemini(80, resetsAt: 10), now: 11), .segments(claude + [gem(0)]))
    }

    func testPillModeDefaultsToClaude() {
        let d = UserDefaults(suiteName: "PillComposerTests-\(UUID().uuidString)")!
        XCTAssertEqual(PillMode.read(from: d), .claude)
        d.set("both", forKey: PillMode.defaultsKey)
        XCTAssertEqual(PillMode.read(from: d), .both)
        d.set("nonsense", forKey: PillMode.defaultsKey)
        XCTAssertEqual(PillMode.read(from: d), .claude)
    }
}
