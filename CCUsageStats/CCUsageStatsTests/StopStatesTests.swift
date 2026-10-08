import XCTest
@testable import CCUsageStats

/// What a finished turn (`Stop` / `StopFailure`) really means: background
/// work still running, a question left for the user, or why it failed.
final class StopStatesTests: XCTestCase {
    private func rec(_ event: String, _ extra: String = "", cwd: String = "/Users/u/Projects/demo") -> SessionRecord {
        let json = #"{"v":1,"pid":1,"session_id":"s1","hook_event":"\#(event)","cwd":"\#(cwd)"\#(extra)}"#
        return SessionRecord.decode(Data(json.utf8), updatedAt: 1_000)!
    }

    private func tasks(_ items: String...) -> String {
        #","background_tasks":[\#(items.joined(separator: ","))]"#
    }

    private func shell(_ command: String, status: String = "running") -> String {
        #"{"id":"t","type":"shell","status":"\#(status)","description":"d","command":"\#(command)"}"#
    }

    private let subagent = #"{"id":"a","type":"subagent","status":"running","description":"Explore repo","agent_type":"Explore"}"#

    // MARK: Background tasks

    func testStopWithBackgroundWorkKeepsTheSessionListed() {
        let r = rec("Stop", tasks(shell("swift test 2>&1 | tail -5"), subagent))
        XCTAssertEqual(r.status, .background)
        XCTAssertEqual(r.backgroundTaskCount, 2)
        XCTAssertTrue(SessionStatus.background.isActive, "still listed")
        XCTAssertFalse(SessionStatus.background.needsAttention, "nothing asked of the user")
        let s = RunningSession(record: r, title: "demo")
        XCTAssertEqual(s.statusText, "In background (2)")
        XCTAssertEqual(s.tooltip, "In background (2) — /Users/u/Projects/demo")
    }

    func testStopWithNothingInFlightIsDone() {
        XCTAssertEqual(rec("Stop").status, .done, "older Claude Code: no background_tasks at all")
        XCTAssertEqual(rec("Stop", tasks()).status, .done)
        XCTAssertEqual(rec("Stop", #","background_tasks":"garbage""#).status, .done)
    }

    func testFinishedTasksDontCount() {
        let r = rec("Stop", tasks(shell("make", status: "completed"), shell("x", status: "failed"),
                                  shell("y", status: "killed"), shell("cargo build")))
        XCTAssertEqual(r.backgroundTaskCount, 1)
    }

    /// Servers and followers never finish on their own; a session that left
    /// one running is done, not "in background" forever.
    func testLongLivedServicesDontCount() {
        let services = [
            "npm run dev", "pnpm dev", "yarn start", "bun run dev -- --port 3000", "npm run dev:server",
            "cd web && npm run dev", "npx vite", "vite --port 5173", "next dev", "uvicorn app:app --reload",
            "gunicorn -w 2 app:app", "flask run", "python manage.py runserver", "rails server", "rails s",
            "python3 -m http.server 8000", "php artisan serve", "tail -f /var/log/system.log", "tail -F x.log",
            "jest --watch", "tsc -w", "webpack serve", "nodemon index.js", "docker compose up",
            "kubectl logs -f pod/x", "journalctl -fu nginx", "hugo server", "watch -n 5 ls",
            "fly logs -f", "jest --watchAll", "swift build && npm run dev",
        ]
        for c in services {
            XCTAssertTrue(BackgroundTask(type: "shell", status: "running", command: c, description: nil).isLongLivedService, c)
            XCTAssertEqual(rec("Stop", tasks(shell(c))).status, .done, c)
        }
        let finite = [
            "npm test", "npm run build", "vite build", "pnpm run lint", "swift test", "xcodebuild test -scheme X",
            "docker compose up -d", "tail -n 50 log.txt", "cargo build --release", "pytest -x", "sleep 300",
            "grep -w foo file", "./scripts/release.sh v1.2.0",
            "echo npm run dev; swift test", "printf 'tail -f x' && make", "cat logs/app.log | grep -f patterns",
        ]
        for c in finite {
            XCTAssertFalse(BackgroundTask(type: "shell", status: "running", command: c, description: nil).isLongLivedService, c)
        }
        // A service alongside real work: only the work counts.
        XCTAssertEqual(rec("Stop", tasks(shell("npm run dev"), subagent)).backgroundTaskCount, 1)
    }

    // MARK: Closing questions

    func testClosingQuestionWaitsForInput() {
        let asks = [
            "I've drafted the migration.\n\nShall I apply these changes?",
            "Two options:\n1. Keep\n2. Drop\n\nWhich would you prefer?",
            "Done with the refactor. Do you want me to open a PR as well?",
            "Want me to run the full suite too?",
            "Should I proceed with the rename, or keep the old name?",
            "**Would you like me to commit this?**",
            "Tests pass. OK to merge?",
            "Ready when you are — should we deploy now? ",
            "Can you confirm the target branch?",
            // Only a reply's ending is kept: a long code block's opening fence
            // may be cut off, leaving just its closing one.
            "    return x\n}\n```\n\nWould you like me to continue?",
        ]
        for m in asks {
            XCTAssertTrue(ClosingQuestion.asksUser(m), m)
            XCTAssertEqual(rec("Stop", ",\"last_message\":\(Self.json(m))").status, .waitingForInput, m)
        }
    }

    func testOtherEndingsAreNotQuestions() {
        let not = [
            "", "Done. All 42 tests pass.",
            "Shall I apply these changes? I went ahead and applied them anyway.",
            "Why did it fail? The cache key was stale. Fixed in abc123.",
            "Here's the snippet:\n```swift\nlet ok = shouldIProceed?\n```",
            "Should I mention that the flag is off by default? It is, and the docs say so.",
            "The question was: why does `x?` crash?",
            "Anything else?",
            "Why did the request proceed?",
        ]
        for m in not {
            XCTAssertFalse(ClosingQuestion.asksUser(m), m)
        }
        XCTAssertFalse(ClosingQuestion.asksUser(nil))
    }

    func testAQuestionOutranksBackgroundWork() {
        let r = rec("Stop", ",\"last_message\":\"Shall I apply these changes?\"" + tasks(subagent))
        XCTAssertEqual(r.status, .waitingForInput)
    }

    // MARK: Failure reasons

    func testFailureReasons() {
        XCTAssertEqual(StopFailureReason(error: "rate_limit"), .usageLimit)
        for e in ["overloaded", "server_error"] { XCTAssertEqual(StopFailureReason(error: e), .unreachable, e) }
        for e in ["authentication_failed", "oauth_org_not_allowed", "account_on_hold", "billing_error",
                  "cloud_credential_error"] {
            XCTAssertEqual(StopFailureReason(error: e), .auth, e)
        }
        for e in ["invalid_request", "model_not_found", "max_output_tokens", "unknown", "brand_new", nil] {
            XCTAssertEqual(StopFailureReason(error: e), .other, e ?? "nil")
        }
    }

    func testUsageLimitTooltipShowsWhenItResets() {
        let r = rec("StopFailure", #","error":"rate_limit","last_message":"You've reached your Fable limit. Run /usage-credits to continue or switch models with /model.""#)
        XCTAssertEqual(r.status, .error)
        XCTAssertEqual(r.failure, .usageLimit)
        let s = RunningSession(record: r, title: "demo")
        XCTAssertEqual(s.statusText, "Usage limit reached")
        let capped = RateLimitsSnapshot(fiveHour: WindowSnapshot(usedPercentage: 100, resetsAt: 1_000 + 2 * 3600 + 600), sevenDay: nil)
        XCTAssertEqual(s.tooltip(limits: capped, now: 1_000),
                       "Usage limit reached, resets in 2h 10m — /Users/u/Projects/demo\nYou've reached your Fable limit. Run /usage-credits to continue or switch models with /model.")
        XCTAssertEqual(s.tooltip(limits: nil, now: 1_000),
                       "Usage limit reached — /Users/u/Projects/demo\nYou've reached your Fable limit. Run /usage-credits to continue or switch models with /model.")
        XCTAssertFalse(s.tooltip(limits: RateLimitsSnapshot(fiveHour: WindowSnapshot(usedPercentage: 100, resetsAt: 900), sevenDay: nil),
                                 now: 1_000).contains("resets"), "a reset in the past is stale data")
    }

    func testOtherFailuresSayWhatHappened() {
        let unreachable = RunningSession(record: rec("StopFailure", #","error":"server_error","last_message":"API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)""#), title: "demo")
        XCTAssertEqual(unreachable.statusText, "Can't reach Claude")
        XCTAssertEqual(unreachable.tooltip(limits: RateLimitsSnapshot(fiveHour: WindowSnapshot(usedPercentage: 100, resetsAt: 5_000), sevenDay: nil), now: 1_000),
                       "Can't reach Claude — /Users/u/Projects/demo\nAPI Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)",
                       "a reset time only belongs to a usage limit")
        XCTAssertEqual(RunningSession(record: rec("StopFailure", #","error":"authentication_failed""#), title: "x").tooltip,
                       "Sign-in or account problem — /Users/u/Projects/demo")
        XCTAssertEqual(RunningSession(record: rec("StopFailure"), title: "x").tooltip, "Error — /Users/u/Projects/demo",
                       "older Claude Code: no error field")
        XCTAssertEqual(RunningSession(record: rec("StopFailure", #","error":"max_output_tokens""#), title: "x").statusText,
                       "Error")
    }

    // MARK: Limit reset from the app's own usage data

    func testLimitResetIsTheLatestCappedWindow() {
        let w = { (p: Double, r: Int64) in WindowSnapshot(usedPercentage: p, resetsAt: r) }
        let fable = "You've reached your Fable limit. Run /usage-credits to continue."
        XCTAssertNil(RateLimitsSnapshot(fiveHour: w(80, 2_000), sevenDay: w(50, 9_000)).limitResetsAt(now: 1_000, message: fable),
                     "nothing capped: no claim")
        XCTAssertEqual(RateLimitsSnapshot(fiveHour: w(100, 2_000), sevenDay: w(50, 9_000)).limitResetsAt(now: 1_000, message: nil), 2_000)
        XCTAssertEqual(RateLimitsSnapshot(fiveHour: w(100, 2_000), sevenDay: w(100, 9_000)).limitResetsAt(now: 1_000, message: nil), 9_000,
                       "blocked until every capped window resets")
        XCTAssertNil(RateLimitsSnapshot(fiveHour: w(100, 900), sevenDay: nil).limitResetsAt(now: 1_000, message: nil), "already reset")
        // Per-model windows are separate quotas: one counts only when the
        // message names its model.
        let models = RateLimitsSnapshot(fiveHour: w(100, 2_000), sevenDay: w(40, 9_000),
                                        models: ["seven_day_fable": w(100, 7_000), "seven_day_opus": w(100, 8_000)])
        XCTAssertEqual(models.limitResetsAt(now: 1_000, message: fable), 7_000)
        XCTAssertEqual(models.limitResetsAt(now: 1_000, message: "API Error: Rate limit reached"), 2_000)
        XCTAssertNil(RateLimitsSnapshot(fiveHour: w(10, 2_000), sevenDay: nil, models: ["seven_day_opus": w(100, 8_000)])
            .limitResetsAt(now: 1_000, message: fable), "another model's cap says nothing about this one")
    }

    // MARK: Ranking

    func testBackgroundRanksBelowEverythingBusy() {
        let bg = RunningSession(record: rec("Stop", tasks(subagent)), title: "a")
        let compacting = RunningSession(record: rec("PreCompact"), title: "b")
        XCTAssertEqual(RunningSessions.mostSevere([bg]), .background)
        XCTAssertEqual(RunningSessions.mostSevere([bg, compacting]), .compacting)
    }

    private static func json(_ s: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed]), encoding: .utf8)!
            .dropFirst().dropLast().description
    }
}
