import Foundation

/// The popover row that offers the browser sign-in for per-model usage.
///
/// Two different users see it. One never connected an account and is being
/// offered something new. The other had a connected account whose grant the
/// server has since refused, and is running on the pasted token behind it:
/// for them the per-model rows were there yesterday, and "connect your
/// account" explains nothing.
enum ReconnectPrompt: Equatable {
    case connect
    case reconnect

    static func decide(
        needsReauthorization: Bool,
        authState: AuthState,
        source: MenuViewModel.ClaudeSource
    ) -> ReconnectPrompt? {
        // Suppressed when there is no working token at all: "connect for the
        // model meter" is noise next to "token rejected, set a token".
        guard needsReauthorization, !authState.lacksWorkingToken else { return nil }
        // A scoped session was stored at launch, so the flag can only be the
        // poller reporting that the server refused it.
        return source == .connectedAccount ? .reconnect : .connect
    }

    var message: String {
        switch self {
        case .connect: return "Connect your account to see per-model weekly usage."
        case .reconnect: return "Claude account connection expired. Reconnect to see per-model weekly usage."
        }
    }

    var buttonLabel: String {
        switch self {
        case .connect: return "Connect Claude account"
        case .reconnect: return "Reconnect Claude account"
        }
    }
}
