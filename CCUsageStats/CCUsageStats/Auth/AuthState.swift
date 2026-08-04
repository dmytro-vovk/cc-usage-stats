import Foundation

/// `CaseIterable` so exhaustiveness tests enumerate the real case list rather
/// than a hardcoded copy that silently stops covering new states.
enum AuthState: Equatable, CaseIterable {
    case unknown
    case ok
    /// Nothing stored to authenticate with. Distinct from `invalidToken`: the
    /// API has said nothing, so reporting a token as "rejected" would be a
    /// fabrication — and the fix is Set Token, not re-import.
    case noToken
    case invalidToken
    /// The connected Claude account's OAuth grant is gone — revoked, expired
    /// beyond refresh, or missing `user:profile` — and there is no pasted
    /// token to fall back to. Distinct from `invalidToken`: the fix is to
    /// reconnect the account, not to re-import a token from Claude Code's
    /// Keychain, and telling the user the latter sends them somewhere that
    /// cannot help.
    case connectionExpired
    case notSubscriber
    case offline

    /// No credential the poller can work with, whichever way it got there.
    /// The menubar readout and the token-expiry caption both key off this.
    ///
    /// `connectionExpired` belongs here for a second reason: it is what
    /// suppresses the "Connect your account to see per-model weekly usage."
    /// row, which would otherwise sit under "connection expired" offering a
    /// cosmetic upgrade the user has just been told they no longer have.
    var lacksWorkingToken: Bool {
        self == .noToken || self == .invalidToken || self == .connectionExpired
    }
}
