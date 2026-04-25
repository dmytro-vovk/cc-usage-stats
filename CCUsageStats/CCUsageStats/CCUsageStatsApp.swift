import SwiftUI

@main
struct CCUsageStatsApp: App {
    @StateObject private var vm = MenuViewModel()

    init() {
        // Phase 1 cleanup migration. One-shot; sentinel guards re-runs.
        try? Phase1Cleanup.run(
            settingsURL: Paths.claudeSettings,
            configURL: Paths.configFile,
            sentinelURL: Paths.appSupportDir.appendingPathComponent("v2-migrated")
        )
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarDropdown(vm: vm)
        } label: {
            MenuBarLabel(vm: vm)
                .onAppear { vm.start() }
        }
        // .window style draws a SwiftUI panel that re-renders live, so the
        // "Last update Xs ago" caption ticks each second while open. .menu
        // style snapshots the items at open time and never updates.
        .menuBarExtraStyle(.window)
    }
}
