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

    func testPillModeDefaultsToClaude() {
        let d = UserDefaults(suiteName: "PillComposerTests-\(UUID().uuidString)")!
        XCTAssertEqual(PillMode.read(from: d), .claude)
        d.set("both", forKey: PillMode.defaultsKey)
        XCTAssertEqual(PillMode.read(from: d), .both)
        d.set("nonsense", forKey: PillMode.defaultsKey)
        XCTAssertEqual(PillMode.read(from: d), .claude)
    }
}
