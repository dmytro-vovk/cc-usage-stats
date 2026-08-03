import AppKit
import Foundation
import Network
import os

/// PKCE authorization-code flow against Claude's OAuth endpoints.
///
/// Uses Claude Code's public client ID: no public client registration
/// exists for the claude.ai subscription scopes, and the app already
/// depends on that identity implicitly. Only `user:profile` is requested —
/// the minimum this app needs to read /api/oauth/usage.
///
/// The loopback redirect is the only supported path. `manualRedirectURI` is
/// declared for reference but no paste-the-code UI exists: binding an
/// ephemeral loopback port does not fail in practice, and a second
/// redirect path would be an untested branch. If `listenerFailed` ever
/// surfaces in the wild, build the manual path then.
enum OAuthFlow {
    private static let log = Logger(subsystem: "dev.dv.ccusagestats", category: "oauth")

    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeEndpoint = "https://claude.com/cai/oauth/authorize"
    static let tokenEndpoint = "https://platform.claude.com/v1/oauth/token"
    static let manualRedirectURI = "https://platform.claude.com/oauth/code/callback"
    static let scope = "user:profile"

    enum FlowError: Error, Equatable {
        case stateMismatch
        case badResponse(Int)
        case malformedTokenResponse
        case listenerFailed
        case cancelled
    }

    static func authorizeURL(challenge: String, state: String, redirectURI: String) -> URL {
        var c = URLComponents(string: authorizeEndpoint)!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        return c.url!
    }

    /// Exchanges an authorization code. The token endpoint takes a JSON
    /// body, not form encoding.
    static func exchange(
        code: String,
        verifier: String,
        state: String,
        redirectURI: String,
        session: URLSession = .shared,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) async throws -> OAuthSession {
        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
            "state": state,
        ]
        return try await post(body: body, session: session, now: now)
    }

    static func refresh(
        _ existing: OAuthSession,
        session: URLSession = .shared,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) async throws -> OAuthSession {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": existing.refreshToken,
            "client_id": clientID,
        ]
        return try await post(body: body, session: session, now: now)
    }

    private static func post(
        body: [String: Any],
        session: URLSession,
        now: Int64
    ) async throws -> OAuthSession {
        var req = URLRequest(url: URL(string: tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw FlowError.badResponse(0)
        }
        guard http.statusCode == 200 else {
            throw FlowError.badResponse(http.statusCode)
        }
        guard let parsed = OAuthSession.fromTokenResponse(data, now: now) else {
            throw FlowError.malformedTokenResponse
        }
        return parsed
    }
}

/// Serializes refreshes so two concurrent polls cannot both rotate the
/// refresh token — the second rotation would invalidate the first and sign
/// the user out.
actor OAuthTokenProvider {
    /// A failed refresh is not the same thing as a bad session. Collapsing
    /// them makes an offline laptop look like it needs reauthorization, and
    /// starves the offline detector of the transient failures it counts.
    enum TokenResult {
        case token(String)
        /// No session stored, or the server rejected the refresh outright.
        case unusable
        /// Refresh could not be completed right now (network, 5xx).
        case temporarilyUnavailable(String)
    }

    private var session: OAuthSession?
    private var inFlight: Task<OAuthSession, Error>?

    init(session: OAuthSession?) { self.session = session }

    /// Returns a usable access token, refreshing first when close to expiry.
    func accessToken(now: Int64 = Int64(Date().timeIntervalSince1970)) async -> TokenResult {
        guard let current = session else { return .unusable }
        guard current.isExpiring(now: now) else { return .token(current.accessToken) }

        // Single-flight: two concurrent polls must not both rotate the
        // refresh token, or the second rotation invalidates the first.
        if let existing = inFlight {
            if let fresh = try? await existing.value { return .token(fresh.accessToken) }
            return .temporarilyUnavailable("refresh in flight failed")
        }

        let task = Task { () throws -> OAuthSession in
            let fresh = try await OAuthFlow.refresh(current, now: now)
            try? OAuthSessionStore.write(fresh)
            return fresh
        }
        inFlight = task
        do {
            let fresh = try await task.value
            inFlight = nil
            session = fresh
            return .token(fresh.accessToken)
        } catch {
            inFlight = nil
            // A 4xx on refresh means the grant is gone for good; anything
            // else (transport, 5xx) is worth retrying on the next poll.
            if case OAuthFlow.FlowError.badResponse(let code) = error,
               (400..<500).contains(code) {
                session = nil
                return .unusable
            }
            return .temporarilyUnavailable(String(describing: error))
        }
    }

    func hasProfileScope() -> Bool { session?.hasProfileScope ?? false }
}
