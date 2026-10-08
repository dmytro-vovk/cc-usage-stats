import SwiftUI

struct CCUsageStatsApp: App {
    @StateObject private var vm = MenuViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Phase 1 cleanup migration. One-shot; sentinel guards re-runs.
        // Skipped under test: the unit bundle is hosted in this app, so every
        // `xcodebuild test` launches instances that would otherwise run a
        // migration over real files. Paths redirect under test as well — this
        // is the second lock on the same door.
        guard !TestEnvironment.isRunningTests else { return }
        try? Phase1Cleanup.run(
            settingsURL: Paths.claudeSettings,
            configURL: Paths.configFile,
            sentinelURL: Paths.appSupportDir.appendingPathComponent("v2-migrated")
        )
        UsageMCPMigration.runAtLaunch()
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

/// Receives `ccusagestats://` URLs (Info.plist `CFBundleURLTypes`).
///
/// Through our own `kAEGetURL` handler rather than `application(_:open:)`,
/// which a MenuBarExtra-only SwiftUI app never receives. Installed before
/// launch finishes (so the URL that launched the app arrives) and again
/// after, in case SwiftUI claimed the event in between.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) { claimURLEvents() }
    func applicationDidFinishLaunching(_ notification: Notification) { claimURLEvents() }

    private func claimURLEvents() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let url = Self.url(from: event) else { return }
        AppURLRouter.shared.handle(url)
    }

    nonisolated static func url(from event: NSAppleEventDescriptor) -> URL? {
        event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue.flatMap(URL.init(string:))
    }
}
