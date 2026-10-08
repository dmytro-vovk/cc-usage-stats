import AppKit
import os

/// `ccusagestats://` commands, for launchers (Raycast, Shortcuts) and
/// screenshot automation:
/// - `refresh` — poll now
/// - `settings?tab=general|accounts|alerts` — open Settings on that tab
/// Anything else is ignored (and logged). There is deliberately no "open the
/// dropdown": a MenuBarExtra panel ignores every in-process click
/// (`performClick`, the button's action, synthetic `NSEvent`s) — only a real
/// system click opens it.
enum AppURLCommand: Equatable {
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
        case .refresh: vm.pollNow()
        case .settings(let tab): vm.openSettings(tab: tab)
        }
    }
}
