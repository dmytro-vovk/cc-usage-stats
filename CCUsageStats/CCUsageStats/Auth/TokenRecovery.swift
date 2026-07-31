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
        /// Nothing usable in the Keychain, with the probe's reason attached so
        /// the message can name it: an expired token, a denied prompt and an
        /// MCP-only entry each need a different next step from the user.
        case noneAvailable(ClaudeCodeKeychainProbe.Outcome)
    }

    static func decide(
        rejected: String?,
        found: ClaudeCodeKeychainProbe.Outcome
    ) -> Outcome {
        guard case .found(let candidate) = found else { return .noneAvailable(found) }
        if let rejected, rejected == candidate.token { return .sameTokenRejected }
        return .adopted(candidate)
    }
}

/// User-facing wording for a recovery attempt that didn't restore polling.
///
/// Separated from the view model so the copy is unit-testable with an injected
/// `now` — the expired case quotes how long ago the token lapsed.
enum RecoveryCopy {
    /// Same advice in two grammatical positions — mid-sentence after "or", and
    /// standing alone. Composing one from the other would need string surgery
    /// for a single capital letter.
    private static let pasteClause =
        "run `claude setup-token` and paste the value it prints — that one is long-lived."
    private static let pasteSentence =
        "Run `claude setup-token` and paste the value it prints — that one is long-lived."

    /// nil when the outcome needs no explanation (a token was adopted).
    static func message(for outcome: TokenRecovery.Outcome, now: Date) -> String? {
        switch outcome {
        case .adopted:
            return nil

        case .sameTokenRejected:
            return "Claude Code's Keychain still holds the rejected token. Use Claude Code once "
                + "to refresh it, or paste the output of `claude setup-token` — that token is long-lived."

        case .noneAvailable(let probe):
            return message(for: probe, now: now)
        }
    }

    static func message(for probe: ClaudeCodeKeychainProbe.Outcome, now: Date) -> String {
        switch probe {
        case .found:
            // Unreachable through `TokenRecovery.decide`; kept total so a future
            // caller can't fall off the end of the switch.
            return "Claude Code's Keychain holds a usable token."

        case .expired(let deadline):
            // Says what was found, not what the CLI did: a rotated token in an
            // envelope shape this build can't parse would also land here, and
            // "the CLI hasn't refreshed it" would then be a fabrication.
            let ago = RelativeTime.format(seconds: Int64(max(0, now.timeIntervalSince(deadline))))
            return "Claude Code's token expired \(ago) ago, and no fresher one was found. "
                + "Use Claude Code once to rotate it, or \(pasteClause)"

        case .accessDenied:
            return "macOS denied access to Claude Code's Keychain item, so its token couldn't be read. "
                + "Click again and choose Allow, or \(pasteClause)"

        case .noClaudeToken:
            // Covers MCP-only entries, an API key in the token slot, and any
            // shape the parser doesn't recognize — so it can't name just one.
            return "Claude Code's Keychain entries hold no claude.ai OAuth token — MCP logins, an API "
                + "key, or a format this build doesn't recognize. \(pasteSentence)"

        case .noEntries:
            return "No Claude Code credentials in Keychain. \(pasteSentence)"
        }
    }
}
