import XCTest
@testable import CCUsageStats

@MainActor
final class CodexMonitorTests: XCTestCase {
    func testOnlySessionsChangesTriggerARescan() {
        let m = CodexMonitor(sessionsDirectory: URL(fileURLWithPath: "/u/.codex/sessions"),
                             authURL: URL(fileURLWithPath: "/u/.codex/auth.json"))
        XCTAssertTrue(m.isUnderSessions("/u/.codex/sessions/"))
        XCTAssertTrue(m.isUnderSessions("/u/.codex/sessions/2026/10/07/"))
        XCTAssertFalse(m.isUnderSessions("/u/.codex/"))
        XCTAssertFalse(m.isUnderSessions("/u/.codex/sessions-old/"))
        XCTAssertFalse(m.isUnderSessions("/u/.codex/sqlite/"))
    }

    func testTrackingDefaultsOff() {
        let d = UserDefaults(suiteName: "CodexMonitorTests-\(UUID().uuidString)")!
        let m = CodexMonitor(defaults: d)
        XCTAssertFalse(m.trackingEnabled)
        XCTAssertFalse(m.livePollingEnabled)
        XCTAssertNil(m.snapshot)
        m.trackingEnabled = true
        XCTAssertTrue(CodexMonitor(defaults: d).trackingEnabled)
    }

    func testInitialScanPublishesWithLivePollingOff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cm-\(UUID().uuidString)/sessions/2026/10/07")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let line = #"{"timestamp":"2026-10-07T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":12,"window_minutes":10080,"resets_at":9999999999}}}}"#
        try line.write(to: root.appendingPathComponent("rollout-x.jsonl"), atomically: true, encoding: .utf8)
        let sessions = root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let d = UserDefaults(suiteName: "CodexMonitorTests-\(UUID().uuidString)")!
        d.set(true, forKey: CodexMonitor.trackingKey)
        let m = CodexMonitor(sessionsDirectory: sessions, authURL: sessions.appendingPathComponent("none.json"), defaults: d)
        m.start()
        defer { m.stop() }
        for _ in 0..<50 where m.snapshot == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(m.snapshot?.windows.first?.usedPercent, 12)
    }

    func testAbsurdPercentagesAreRejected() {
        let line = #"{"timestamp":"2026-10-07T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":1e100,"window_minutes":300,"resets_at":5}}}}"#
        XCTAssertNil(CodexRolloutParser.parse(line: line))
        XCTAssertNil(CodexLiveClient.parseUsage(Data(#"{"rate_limit":{"primary_window":{"used_percent":-1e100,"limit_window_seconds":18000,"reset_at":1}}}"#.utf8), observedAt: 0))
    }

    func testLivePollingPublishesTheAppServerReadingOrItsError() async throws {
        let d = UserDefaults(suiteName: "CodexMonitorTests-\(UUID().uuidString)")!
        d.set(true, forKey: CodexMonitor.trackingKey)
        d.set(true, forKey: CodexMonitor.livePollingKey)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("cm-\(UUID().uuidString)/sessions")
        let reading = CodexSnapshot(windows: [CodexWindow(usedPercent: 33, windowMinutes: 10080, resetsAt: 9_999_999_999)],
                                    planType: "prolite", observedAt: 100, source: .appServer)
        let m = CodexMonitor(sessionsDirectory: empty, authURL: empty.appendingPathComponent("none.json"), defaults: d,
                             liveRead: { _ in .success(reading) })
        m.start()
        defer { m.stop() }
        for _ in 0..<50 where m.snapshot == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(m.snapshot, reading)
        XCTAssertNil(m.liveError)

        let failing = CodexMonitor(sessionsDirectory: empty, authURL: empty.appendingPathComponent("none.json"), defaults: d,
                                   liveRead: { _ in .failure(CodexLiveReadError(message: "Codex: auth required")) })
        failing.start()
        defer { failing.stop() }
        for _ in 0..<50 where failing.liveError == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(failing.liveError, "Codex: auth required")
        XCTAssertNil(failing.snapshot)
    }

    /// Counts live reads and holds the first one until released.
    private actor SlowFirstRead {
        private(set) var calls = 0
        private var release: CheckedContinuation<Void, Never>?
        private var released = false
        func enter() async {
            calls += 1
            guard calls == 1, !released else { return }
            await withCheckedContinuation { release = $0 }
        }
        func letGo() { released = true; release?.resume(); release = nil }
    }

    /// Live polling switched off and on again while a poll is in flight: the
    /// in-flight answer is discarded (it belongs to the old setting), so the
    /// new request must run after it instead of being dropped for 300 s.
    func testLivePollRequestedDuringAPollRunsAfterIt() async throws {
        let d = UserDefaults(suiteName: "CodexMonitorTests-\(UUID().uuidString)")!
        d.set(true, forKey: CodexMonitor.trackingKey)
        d.set(true, forKey: CodexMonitor.livePollingKey)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("cm-\(UUID().uuidString)/sessions")
        let reading = CodexSnapshot(windows: [CodexWindow(usedPercent: 33, windowMinutes: 10080, resetsAt: 9_999_999_999)],
                                    planType: "prolite", observedAt: 100, source: .appServer)
        let gate = SlowFirstRead()
        let m = CodexMonitor(sessionsDirectory: empty, authURL: empty.appendingPathComponent("none.json"), defaults: d,
                             liveRead: { _ in await gate.enter(); return .success(reading) })
        m.start()
        defer { m.stop() }
        for _ in 0..<100 { if await gate.calls == 1 { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        m.livePollingEnabled = false
        m.livePollingEnabled = true
        await gate.letGo()
        for _ in 0..<100 where m.snapshot == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(m.snapshot, reading)
        let calls = await gate.calls
        XCTAssertEqual(calls, 2)
    }

    /// FSEvents reports resolved paths; `~/.codex` is a symlink in dotfile setups.
    func testEventsUnderASymlinkedCodexHomeCount() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("cm-\(UUID().uuidString)")
        let real = base.appendingPathComponent("dotfiles/codex/sessions")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let link = base.appendingPathComponent(".codex")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base.appendingPathComponent("dotfiles/codex"))
        let m = CodexMonitor(sessionsDirectory: link.appendingPathComponent("sessions"), authURL: link.appendingPathComponent("auth.json"))
        XCTAssertTrue(m.isUnderSessions(real.path + "/2026/11/12/"))
        XCTAssertTrue(m.isUnderSessions(link.path + "/sessions/"))
        XCTAssertFalse(m.isUnderSessions(base.appendingPathComponent("dotfiles/codex/sqlite").path + "/"))
    }
}
