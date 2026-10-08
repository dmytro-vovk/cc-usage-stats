import AppKit

/// `-CCUSAppearance light|dark` forces the app's appearance, whatever the
/// system uses. For README screenshots: the system-wide setting is the
/// user's, and macOS ignores the old per-app keys
/// (`NSRequiresAquaSystemAppearance`, `-AppleInterfaceStyle`). Without the
/// flag the app follows the system as usual.
enum AppearanceOverride {
    static let key = "CCUSAppearance"

    static func name(for value: String?) -> NSAppearance.Name? {
        switch value?.lowercased() {
        case "light": return .aqua
        case "dark": return .darkAqua
        default: return nil
        }
    }

    /// Launch arguments land in `UserDefaults`' argument domain.
    static func requested(in defaults: UserDefaults = .standard) -> NSAppearance.Name? {
        name(for: defaults.string(forKey: key))
    }

    /// Applies the override once the application object exists.
    static func installIfRequested() {
        guard let name = requested() else { return }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { NSApp.appearance = NSAppearance(named: name) }
        }
    }
}
