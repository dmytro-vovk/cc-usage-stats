import SwiftUI

@main
struct CCUsageStatsApp: App {
    @StateObject private var vm = MenuViewModel()

    init() {
        let args = CommandLine.arguments
        if args.count >= 2 && args[1] == "statusline" {
            StatuslineMode.runFromCLI() // exits.
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarDropdown(vm: vm)
                .onAppear { vm.start() }
        } label: {
            MenuBarLabel(vm: vm)
        }
        .menuBarExtraStyle(.menu)
    }
}
