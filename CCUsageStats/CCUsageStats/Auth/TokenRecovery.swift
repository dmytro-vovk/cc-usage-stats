import Foundation

/// Decides what happens when the API has rejected the stored token and the user
/// clicks "Re-import from Claude Code Keychain".
///
/// Pure, so the decision is testable without touching a Keychain: the view model
/// supplies the rejected token and whatever the probe found, then acts on the
/// outcome.
enum TokenRecovery {
    enum Outcome: Equatable {
        /// The Keychain holds a different, usable token — adopt it and resume polling.
        case adopted(ClaudeCodeKeychainProbe.ImportedToken)
        /// The Keychain still holds the very token that was just rejected.
        /// Adopting it would 401 again, so tell the user rather than silently
        /// restarting into the same failure.
        case sameTokenRejected
        /// Nothing usable in the Keychain: absent, expired, denied, or an entry
        /// carrying only `mcpOAuth`.
        case noneAvailable
    }

    static func decide(
        rejected: String?,
        candidate: ClaudeCodeKeychainProbe.ImportedToken?
    ) -> Outcome {
        guard let candidate else { return .noneAvailable }
        if let rejected, rejected == candidate.token { return .sameTokenRejected }
        return .adopted(candidate)
    }
}
