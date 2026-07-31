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
    case notSubscriber
    case offline

    /// No credential the poller can work with, whichever way it got there.
    /// The menubar readout and the token-expiry caption both key off this.
    var lacksWorkingToken: Bool { self == .noToken || self == .invalidToken }
}
