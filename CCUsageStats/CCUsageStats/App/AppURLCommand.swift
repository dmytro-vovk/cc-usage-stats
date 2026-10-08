import AppKit
import os

/// `ccusagestats://` commands, for launchers (Raycast, Shortcuts) and
/// screenshot automation:
/// - `open` — show the dropdown
/// - `refresh` — poll now
/// - `settings?tab=general|accounts|alerts` — open Settings on that tab
/// Anything else is ignored (and logged).
enum AppURLCommand: Equatable {
    case open
    case refresh
    case settings(SettingsTab)

    static let scheme = "ccusagestats"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path.isEmpty || components.path == "/",
              components.fragment == nil
        else { return nil }
        let query = components.queryItems ?? []
        switch components.host?.lowercased() {
        case "open" where query.isEmpty: self = .open
        case "refresh" where query.isEmpty: self = .refresh
        case "settings" where query.isEmpty || (query.count == 1 && query[0].name == "tab"):
            let tab = query.first?.value?.lowercased()
            guard let match = tab.map({ t in SettingsTab.allCases.first { $0.title.lowercased() == t } }) ?? .general
            else { return nil }
            self = .settings(match)
        default: return nil
        }
    }
}

/// Runs `ccusagestats://` URLs against the view model. URLs that arrive
/// before the model starts (the one that launched the app) wait for it.
@MainActor
final class AppURLRouter {
    static let shared = AppURLRouter()
    private static let log = Logger(subsystem: "dev.dv.ccusagestats", category: "url")

    private weak var vm: MenuViewModel?
    private var pending: [AppURLCommand] = []

    func attach(_ vm: MenuViewModel) {
        self.vm = vm
        let queued = pending
        pending = []
        queued.forEach(perform)
    }

    func handle(_ url: URL) {
        guard let command = AppURLCommand(url: url) else {
            Self.log.notice("ignored unknown URL \(url.absoluteString, privacy: .public)")
            return
        }
        Self.log.info("URL command \(url.absoluteString, privacy: .public)")
        if vm == nil { pending.append(command) } else { perform(command) }
    }

    private func perform(_ command: AppURLCommand) {
        guard let vm else { return }
        switch command {
        case .open: StatusItemOpener.open()
        case .refresh: vm.pollNow()
        case .settings(let tab): vm.openSettings(tab: tab)
        }
    }
}

/// Opens the MenuBarExtra dropdown as a click on the menu-bar item would.
@MainActor
enum StatusItemOpener {
    static func open() {
        // Already up: just bring it forward rather than toggling it shut.
        if let panel = NSApp.windows.first(where: { $0.isVisible && $0.className.contains("MenuBarExtra") }) {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard let button = NSApp.windows.lazy
            .filter({ $0.className.contains("NSStatusBarWindow") })
            .compactMap({ findButton(in: $0.contentView) })
            .first
        else { return }
        NSApp.activate(ignoringOtherApps: true)
        button.performClick(nil)
    }

    private static func findButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews { if let hit = findButton(in: sub) { return hit } }
        return nil
    }
}
