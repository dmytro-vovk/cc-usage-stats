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
        .menuBarExtraStyle(.menu)
    }
}
