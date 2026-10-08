import XCTest
@testable import CCUsageStats

/// Per-window alert rules as wired through the view model. The settings it
/// writes live in the app's real defaults domain (the app hosts the tests),
/// so every key touched is restored afterwards.
@MainActor
final class MenuViewModelAlertTests: XCTestCase {
    private let keys = [
        "cc-usage-stats.warningEnabled", "cc-usage-stats.warningThreshold",
        "cc-usage-stats.weeklyWarningEnabled", "cc-usage-stats.weeklyWarningThreshold",
        "cc-usage-stats.modelWarningEnabled", "cc-usage-stats.modelWarningThreshold",
        "cc-usage-stats.resetAnnouncement", "cc-usage-stats.colorByPace", "cc-usage-stats.paceThreshold",
    ]
    private var saved: [String: Any] = [:]

    override func setUp() {
        saved = [:]
        for k in keys { if let v = UserDefaults.standard.object(forKey: k) { saved[k] = v } }
    }

    override func tearDown() {
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
        for (k, v) in saved { UserDefaults.standard.set(v, forKey: k) }
    }

    private func snapshot(five: Double, seven: Double, fable: Double, resets: Int64 = 2_000_000) -> RateLimitsSnapshot {
        RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: five, resetsAt: resets),
            sevenDay: WindowSnapshot(usedPercentage: seven, resetsAt: resets),
            models: ["seven_day_fable": WindowSnapshot(usedPercentage: fable, resetsAt: resets)]
        )
    }

    private func viewModel() -> MenuViewModel {
        let vm = MenuViewModel()
        vm.warningEnabled = true
        vm.warningThreshold = 90
        vm.weeklyWarningEnabled = true
        vm.weeklyWarningThreshold = 60
        vm.modelWarningEnabled = false
        vm.resetAnnouncement = .ranLow
        return vm
    }

    func testEachWindowKindUsesItsOwnThreshold() {
        let vm = viewModel()
        XCTAssertEqual(vm.alertOutcome(for: snapshot(five: 50, seven: 50, fable: 50)), AlertOutcome())
        // 5h 85 < 90, Fable warning off — only the weekly 60 sounds.
        XCTAssertEqual(vm.alertOutcome(for: snapshot(five: 85, seven: 65, fable: 95)),
                       AlertOutcome(warning: true))
        // Once per window: weekly bouncing back over 60 stays quiet.
        XCTAssertEqual(vm.alertOutcome(for: snapshot(five: 85, seven: 55, fable: 95)), AlertOutcome())
        XCTAssertEqual(vm.alertOutcome(for: snapshot(five: 85, seven: 65, fable: 95)), AlertOutcome())
        // The model window reaching its limit always sounds.
        XCTAssertEqual(vm.alertOutcome(for: snapshot(five: 85, seven: 65, fable: 100)),
                       AlertOutcome(limitReached: true))
    }

    func testResetOfAWindowThatRanLowIsAnnounced() {
        let vm = viewModel()
        _ = vm.alertOutcome(for: snapshot(five: 10, seven: 50, fable: 10))
        _ = vm.alertOutcome(for: snapshot(five: 10, seven: 70, fable: 10))
        let next = vm.alertOutcome(for: snapshot(five: 0, seven: 0, fable: 0, resets: 2_000_000 + 86_400))
        XCTAssertEqual(next, AlertOutcome(reset: true))
    }

    func testQuietResetIsSilentUnderRanLow() {
        let vm = viewModel()
        _ = vm.alertOutcome(for: snapshot(five: 10, seven: 10, fable: 10))
        XCTAssertEqual(vm.alertOutcome(for: snapshot(five: 0, seven: 0, fable: 0, resets: 2_000_000 + 86_400)),
                       AlertOutcome())
    }

    func testColoringFollowsTheSettings() {
        let vm = viewModel()
        vm.colorByPace = false
        XCTAssertEqual(vm.coloring, .absolute)
        vm.colorByPace = true
        vm.paceThreshold = 2
        XCTAssertEqual(vm.coloring, UsageColoring(byPace: true, burnRateThreshold: 2))
    }
}
