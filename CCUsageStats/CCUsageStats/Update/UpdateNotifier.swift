import AppKit
import UserNotifications

/// Announces a newer release. Tests inject a spy.
@MainActor
protocol UpdateNotifying: AnyObject {
    func notify(_ release: LatestRelease)
}

/// Posts a macOS notification for a newer release; clicking it opens the
/// release page. Permission is asked for the first time a release is
/// actually announced, not at launch, so a user who is always current is
/// never prompted. If permission is refused, the dropdown and Settings
/// links remain the only signal.
@MainActor
final class UpdateNotifier: NSObject, UpdateNotifying, UNUserNotificationCenterDelegate {
    static let shared = UpdateNotifier()
    nonisolated static let urlKey = "releasePageURL"

    /// Becomes the notification-center delegate, so a click on the
    /// notification reaches us. Call once at launch (not in test hosts).
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func notify(_ release: LatestRelease) {
        let tag = release.tag
        let page = release.pageURL.absoluteString
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "Update available: \(tag)"
            content.body = "A newer cc-usage-stats is out. Click to open the release page."
            content.sound = .default
            content.userInfo = [Self.urlKey: page]
            let request = UNNotificationRequest(identifier: "update-\(tag)", content: content, trigger: nil)
            try? await center.add(request)
        }
    }

    /// Opens the release page. Only GitHub https links, like the menu link.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.notification.request.content.userInfo[Self.urlKey] as? String
        completionHandler()
        guard let raw, let url = URL(string: raw), url.scheme == "https",
              url.host?.lowercased() == "github.com" else { return }
        Task { @MainActor in NSWorkspace.shared.open(url) }
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
