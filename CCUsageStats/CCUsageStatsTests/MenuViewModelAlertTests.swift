import XCTest
@testable import CCUsageStats

/// Per-window alert rules as wired through the view model. Each view model
/// gets its own throwaway defaults domain: the app hosts the tests, so
/// `.standard` is the user's real preferences.
@MainActor
final class MenuViewModelAlertTests: XCTestCase {
    /// A fresh defaults domain, deleted when the test ends.
    private func throwawayDefaults() -> UserDefaults {
        let name = "MenuViewModelAlertTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func snapshot(
        five: Double, seven: Double, fable: Double, resets: Int64 = 2_000_000, capturedAt: Int64 = 1_000_000
    ) -> CachedState {
        CachedState(capturedAt: capturedAt, snapshot: RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: five, resetsAt: resets),
            sevenDay: WindowSnapshot(usedPercentage: seven, resetsAt: resets),
            models: ["seven_day_fable": WindowSnapshot(usedPercentage: fable, resetsAt: resets)]
        ))
    }

    private func viewModel() -> MenuViewModel {
        let vm = MenuViewModel(defaults: throwawayDefaults())
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
        XCTAssertEqual(vm.alertOutcome(now: 1_000_000, for: snapshot(five: 50, seven: 50, fable: 50)), AlertOutcome())
        // 5h 85 < 90, Fable warning off — only the weekly 60 sounds.
        XCTAssertEqual(vm.alertOutcome(now: 1_000_000, for: snapshot(five: 85, seven: 65, fable: 95)),
                       AlertOutcome(warning: true))
        // Once per window: weekly bouncing back over 60 stays quiet.
        XCTAssertEqual(vm.alertOutcome(now: 1_000_000, for: snapshot(five: 85, seven: 55, fable: 95)), AlertOutcome())
        XCTAssertEqual(vm.alertOutcome(now: 1_000_000, for: snapshot(five: 85, seven: 65, fable: 95)), AlertOutcome())
        // The model window reaching its limit always sounds.
        XCTAssertEqual(vm.alertOutcome(now: 1_000_000, for: snapshot(five: 85, seven: 65, fable: 100)),
                       AlertOutcome(limitReached: true))
    }

    func testResetOfAWindowThatRanLowIsAnnounced() {
        let vm = viewModel()
        _ = vm.alertOutcome(now: 1_000_000, for: snapshot(five: 10, seven: 50, fable: 10))
        _ = vm.alertOutcome(now: 1_000_000, for: snapshot(five: 10, seven: 70, fable: 10))
        let next = vm.alertOutcome(now: 1_000_000, for: snapshot(five: 0, seven: 0, fable: 0, resets: 2_000_000 + 86_400))
        XCTAssertEqual(next, AlertOutcome(reset: true))
    }

    func testQuietResetIsSilentUnderRanLow() {
        let vm = viewModel()
        _ = vm.alertOutcome(now: 1_000_000, for: snapshot(five: 10, seven: 10, fable: 10))
        XCTAssertEqual(vm.alertOutcome(now: 1_000_000, for: snapshot(five: 0, seven: 0, fable: 0, resets: 2_000_000 + 86_400)),
                       AlertOutcome())
    }

    /// A cached window past its reset describes a period that's over; a
    /// late correction to it must not sound.
    func testExpiredWindowDoesNotSound() {
        let vm = viewModel()
        _ = vm.alertOutcome(now: 1_000_000, for: snapshot(five: 10, seven: 55, fable: 10))
        XCTAssertEqual(vm.alertOutcome(now: 2_000_100, for: snapshot(five: 10, seven: 65, fable: 10)), AlertOutcome())
    }

    /// Reconnecting, possibly as another account, starts the latch over —
    /// and the old account's cache, re-read before the first new poll lands,
    /// must not become the new baseline.
    func testRestartingPollingForgetsTheOldAccount() {
        let vm = viewModel()
        let old: Int64 = 2_000_000, new: Int64 = 2_000_000 + 2 * 86_400
        _ = vm.alertOutcome(now: 1_000_000, for: snapshot(five: 10, seven: 50, fable: 10, resets: old))
        _ = vm.alertOutcome(now: 1_000_000, for: snapshot(five: 10, seven: 70, fable: 10, resets: old))
        vm.restartPollingForTest()
        let later = Int64(Date().timeIntervalSince1970) + 60
        // The old account's cache, captured before the restart: held back.
        XCTAssertEqual(vm.alertOutcome(now: 1_000_000, for: snapshot(five: 10, seven: 70, fable: 10, resets: old)),
                       AlertOutcome())
        // The new account's first poll is a baseline, not a reset of a window that ran low.
        XCTAssertEqual(vm.alertOutcome(now: 1_000_000, for: snapshot(five: 5, seven: 10, fable: 5, resets: new,
                                                                     capturedAt: later)),
                       AlertOutcome())
        XCTAssertEqual(vm.alertOutcome(now: 1_000_000, for: snapshot(five: 5, seven: 65, fable: 5, resets: new,
                                                                     capturedAt: later)),
                       AlertOutcome(warning: true))
    }

    /// The app hosts the tests, so `.standard` is the user's real menu-bar
    /// preferences: settings must land in the injected domain and nowhere else.
    func testSettingsStayInTheInjectedDefaults() {
        let keys = [
            "cc-usage-stats.warningEnabled", "cc-usage-stats.warningThreshold",
            "cc-usage-stats.weeklyWarningEnabled", "cc-usage-stats.weeklyWarningThreshold",
            "cc-usage-stats.modelWarningEnabled", "cc-usage-stats.modelWarningThreshold",
            "cc-usage-stats.resetAnnouncement", "cc-usage-stats.colorByPace", "cc-usage-stats.paceThreshold",
            "cc-usage-stats.warningSound", "cc-usage-stats.reachedLimitSound",
            "cc-usage-stats.limitResetSound", "cc-usage-stats.outageSound", "cc-usage-stats.pillMode",
        ]
        let real = UserDefaults.standard
        let before = keys.map { real.object(forKey: $0) as? NSObject }
        // Should a setter regress to `.standard`, undo the leak — touching
        // only keys that changed, so a concurrent edit elsewhere survives.
        addTeardownBlock {
            for (k, v) in zip(keys, before) where real.object(forKey: k) as? NSObject != v {
                if let v { real.set(v, forKey: k) } else { real.removeObject(forKey: k) }
            }
        }
        let d = throwawayDefaults()
        let vm = MenuViewModel(defaults: d)
        vm.warningEnabled = !vm.warningEnabled
        vm.warningThreshold = 37
        vm.weeklyWarningEnabled = !vm.weeklyWarningEnabled
        vm.weeklyWarningThreshold = 38
        vm.modelWarningEnabled = !vm.modelWarningEnabled
        vm.modelWarningThreshold = 39
        vm.resetAnnouncement = .both
        vm.colorByPace = !vm.colorByPace
        vm.paceThreshold = 2.7
        vm.warningSound = SoundPlayer.none
        vm.reachedLimitSound = SoundPlayer.none
        vm.limitResetSound = SoundPlayer.none
        vm.outageSound = SoundPlayer.none
        vm.pillMode = .both
        XCTAssertEqual(keys.map { real.object(forKey: $0) as? NSObject }, before, "the real domain was written")

        let reread = MenuViewModel(defaults: d)
        XCTAssertEqual(reread.warningThreshold, 37)
        XCTAssertEqual(reread.weeklyWarningThreshold, 38)
        XCTAssertEqual(reread.modelWarningThreshold, 39)
        XCTAssertEqual(reread.warningEnabled, vm.warningEnabled)
        XCTAssertEqual(reread.colorByPace, vm.colorByPace)
        XCTAssertEqual(reread.resetAnnouncement, .both)
        XCTAssertEqual(reread.paceThreshold, 2.7)
        XCTAssertEqual(reread.outageSound, SoundPlayer.none)
        XCTAssertEqual(reread.pillMode, .both)
    }

    func testColoringFollowsTheSettings() {
        let vm = viewModel()
        XCTAssertEqual(vm.coloring, UsageColoring(byPace: false, burnRateThreshold: UsageColoring.defaultBurnRateThreshold))
        XCTAssertFalse(vm.coloring.byPace, "a saved pace threshold doesn't matter while colouring is absolute")
        vm.colorByPace = true
        vm.paceThreshold = 2
        XCTAssertEqual(vm.coloring, UsageColoring(byPace: true, burnRateThreshold: 2))
    }
}
