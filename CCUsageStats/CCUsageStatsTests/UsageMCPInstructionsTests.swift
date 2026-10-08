import XCTest
@testable import CCUsageStats

final class UsageMCPInstructionsTests: XCTestCase {
    private let bin = "/Applications/CCUsageStats.app/Contents/MacOS/CCUsageStats"

    func testInstructionsNameTheToolAndBothWaysToConnect() {
        let text = UsageMCPInstructions.text(binary: bin)
        XCTAssertTrue(text.contains("get_usage"))
        XCTAssertTrue(text.contains(ClaudeMCPRegistration.manualCommand(binary: bin)), "Claude Code connect command")
        XCTAssertTrue(text.contains(CodexMCPConfig.block(command: bin)), "Codex config block")
        XCTAssertTrue(text.contains("stale"), "tells agents how to treat old readings")
    }

    func testInstructionsUseTheRunningBinary() {
        let text = UsageMCPInstructions.text(binary: "/Users/u/Applications/CCUsageStats.app/Contents/MacOS/CCUsageStats")
        XCTAssertTrue(text.contains("/Users/u/Applications/"))
    }
}
