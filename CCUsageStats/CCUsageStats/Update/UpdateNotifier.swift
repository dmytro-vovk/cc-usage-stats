import AppKit
import UserNotifications

/// Announces a newer release. Tests inject a spy.
@MainActor
protocol UpdateNotifying: AnyObject {
    /// Whether the announcement was actually handed to the system. False
    /// (permission refused or not answered, or the post failed) means it
    /// has not been made, and the caller may try again later.
    func notify(_ release: LatestRelease) async -> Bool
}

/// Posts a macOS notification for a newer release; clicking it opens the
/// project site's download page. Permission is asked for the first time a release is
/// actually announced, not at launch, so a user who is always current is
/// never prompted. If permission is refused, the dropdown and Settings
/// links remain the only signal.
@MainActor
final class UpdateNotifier: NSObject, UpdateNotifying, UNUserNotificationCenterDelegate {
    static let shared = UpdateNotifier()
    private static let idPrefix = "update-"

    /// Becomes the notification-center delegate, so a click on the
    /// notification reaches us. Call once at launch (not in test hosts).
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func notify(_ release: LatestRelease) async -> Bool {
        let tag = release.tag
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        let content = UNMutableNotificationContent()
        content.title = "Update available: \(tag)"
        content.body = "A newer cc-usage-stats is out. Click to open the download page."
        content.sound = .default
        // Each post gets its own identifier, so a reminder shows as a fresh
        // banner; earlier update notifications are cleared so they never
        // stack. Removal is asynchronous, so it only ever names the older
        // identifiers — it cannot race away the one being added.
        let older = await center.deliveredNotifications()
            .map(\.request.identifier)
            .filter { $0.hasPrefix(Self.idPrefix) }
        if !older.isEmpty { center.removeDeliveredNotifications(withIdentifiers: older) }
        let id = "\(Self.idPrefix)\(tag)-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    /// Opens the project site, like the menu link. The destination is a
    /// constant: nothing carried by the notification can redirect it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
        Task { @MainActor in NSWorkspace.shared.open(AppLinks.website) }
    }

    /// Show the banner even if the app happens to be active.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
