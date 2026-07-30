import Foundation

/// How long a stored token will keep working, and the user-facing wording for it.
///
/// The two token sources have very different lifetimes, which is the whole point
/// of this type. `claude setup-token` PRINTS a long-lived token to the terminal,
/// but what the CLI writes into its Keychain item is the ordinary short-lived
/// access token (observed at 8 hours). So a token imported from the Keychain
/// carries a hard `expiresAt`, while a hand-pasted `setup-token` value has no
/// expiry we can see — an absent expiry therefore means "assume durable", not
/// "assume the worst".
///
/// Both strings live here rather than in the views so the copy is unit-testable
/// with an injected `now`.
enum TokenDurability {
    enum Verdict: Equatable {
        case durable
        case expiring(Date)
        case expired(Date)
    }

    /// Below this much remaining life, the Settings sheet explains that the
    /// just-imported token is short-lived. Set well above the observed 8-hour
    /// lifetime so every Keychain import gets the explanation.
    static let importWarningWindow: TimeInterval = 24 * 3600

    /// Below this much remaining life, the dropdown shows a countdown caption.
    /// Kept short so the hint doesn't sit in the menu all day.
    static let dropdownHintWindow: TimeInterval = 3600

    static func classify(expiresAt: Date?, now: Date) -> Verdict {
        guard let expiresAt else { return .durable }
        return expiresAt <= now ? .expired(expiresAt) : .expiring(expiresAt)
    }

    /// Settings-sheet note shown right after a Keychain import, or nil when the
    /// token is durable (or distant enough not to warrant a warning).
    static func importNotice(expiresAt: Date?, now: Date) -> String? {
        switch classify(expiresAt: expiresAt, now: now) {
        case .durable:
            return nil
        case .expired:
            return "This Keychain token has already expired. Run `claude setup-token` and paste the "
                + "value it prints — that one is long-lived."
        case .expiring(let date):
            let remaining = date.timeIntervalSince(now)
            guard remaining < importWarningWindow else { return nil }
            return "This is Claude Code's own short-lived token — it expires in "
                + "\(RelativeTime.format(seconds: Int64(remaining))), and the menubar will stop "
                + "updating then. For a token that lasts, run `claude setup-token` and paste the "
                + "value it prints instead."
        }
    }

    /// Dropdown caption warning that the token is about to lapse, or nil when
    /// there is nothing worth saying yet.
    static func dropdownCaption(expiresAt: Date?, now: Date) -> String? {
        switch classify(expiresAt: expiresAt, now: now) {
        case .durable:
            return nil
        case .expired:
            return "Token expired — re-import or paste a new one."
        case .expiring(let date):
            let remaining = date.timeIntervalSince(now)
            guard remaining < dropdownHintWindow else { return nil }
            return "Token expires in \(RelativeTime.format(seconds: Int64(remaining)))."
        }
    }
}
