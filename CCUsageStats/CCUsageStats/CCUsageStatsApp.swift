import SwiftUI

@main
struct CCUsageStatsApp: App {
    init() {
        let args = CommandLine.arguments
        if args.count >= 2 && args[1] == "statusline" {
            StatuslineMode.runFromCLI() // exits.
        }
    }

    var body: some Scene {
        MenuBarExtra("cc-usage-stats", systemImage: "gauge.with.dots.needle.33percent") {
            Text("placeholder — ui in later tasks")
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}
