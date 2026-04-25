import SwiftUI

@main
struct CCUsageStatsApp: App {
    var body: some Scene {
        MenuBarExtra("cc-usage-stats", systemImage: "gauge.with.dots.needle.33percent") {
            Text("placeholder")
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}
