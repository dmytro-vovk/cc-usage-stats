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
    // `nonisolated`: the module defaults new declarations to MainActor
    // isolation, but `Logger` is Sendable and this is read from the plain
    // (non-MainActor) `OAuthTokenProvider` actor below — without this the
    // access would need to hop actors just to write a log line.
    nonisolated fileprivate static let log = Logger(subsystem: "dev.dv.ccusagestats", category: "oauth")

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

    /// Full interactive flow: listen, open browser, exchange.
    static func runInteractive(
        timeout: TimeInterval = 300,
        session: URLSession = .shared
    ) async throws -> OAuthSession {
        let verifier = PKCE.makeVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.randomState()

        let listener = try await LoopbackRedirectListener.start()
        defer { listener.stop() }
        let redirectURI = "http://localhost:\(listener.port)/callback"

        NSWorkspace.shared.open(
            authorizeURL(challenge: challenge, state: state, redirectURI: redirectURI)
        )

        let callback = try await listener.waitForCallback(timeout: timeout)
        guard callback.state == state else { throw FlowError.stateMismatch }

        return try await exchange(
            code: callback.code,
            verifier: verifier,
            state: state,
            redirectURI: redirectURI,
            session: session
        )
    }
}

/// Single-shot loopback HTTP listener for the OAuth redirect.
/// Construct with `await LoopbackRedirectListener.start()`.
final class LoopbackRedirectListener {
    struct Callback { let code: String; let state: String }

    private let listener: NWListener
    private var continuation: CheckedContinuation<Callback, Error>?
    private var finished = false
    let port: UInt16

    /// Binds an ephemeral port on loopback only. `requiredLocalEndpoint`
    /// constrains the bind address (macOS 10.15+); without it the listener
    /// accepts connections from the whole LAN.
    static func start() async throws -> LoopbackRedirectListener {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let l = try? NWListener(using: params) else {
            throw OAuthFlow.FlowError.listenerFailed
        }

        // Wait for .ready rather than polling `listener.port` — the port is
        // not assigned until the listener is ready, and a busy-wait on the
        // cooperative executor would block a thread that the listener's own
        // queue may need.
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            var resumed = false
            l.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    guard let p = l.port?.rawValue, p != 0 else {
                        resumed = true
                        cont.resume(throwing: OAuthFlow.FlowError.listenerFailed)
                        return
                    }
                    resumed = true
                    cont.resume(returning: p)
                case .failed, .cancelled:
                    resumed = true
                    cont.resume(throwing: OAuthFlow.FlowError.listenerFailed)
                default:
                    break
                }
            }
            l.start(queue: .main)
        }

        return LoopbackRedirectListener(listener: l, port: port)
    }

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    func waitForCallback(timeout: TimeInterval) async throws -> Callback {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(OAuthFlow.FlowError.cancelled))
            }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""

            let parsed: Callback? = {
                guard let line = request.split(separator: "\r\n").first,
                      let pathPart = line.split(separator: " ").dropFirst().first,
                      let comps = URLComponents(string: "http://localhost\(pathPart)"),
                      let code = comps.queryItems?.first(where: { $0.name == "code" })?.value,
                      let state = comps.queryItems?.first(where: { $0.name == "state" })?.value
                else { return nil }
                return Callback(code: code, state: state)
            }()

            let body = parsed == nil
                ? "Not found."
                : "You can close this window and return to CCUsageStats."
            let status = parsed == nil ? "404 Not Found" : "200 OK"
            let response = """
            HTTP/1.1 \(status)\r
            Content-Type: text/plain; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                conn.cancel()
            })

            // Only a well-formed callback ends the wait. Browsers open
            // speculative preconnect sockets that carry no request, and any
            // stray probe would otherwise abort an in-progress
            // authorization. Failure comes from the timeout alone.
            if let parsed { self.finish(.success(parsed)) }
        }
    }

    private func finish(_ result: Result<Callback, Error>) {
        guard !finished else { return }
        finished = true
        continuation?.resume(with: result)
        continuation = nil
    }

    func stop() { listener.cancel() }
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
    private let urlSession: URLSession

    init(session: OAuthSession?, urlSession: URLSession = .shared) {
        self.session = session
        self.urlSession = urlSession
    }

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
            let fresh = try await OAuthFlow.refresh(current, session: urlSession, now: now)
            do {
                try OAuthSessionStore.write(fresh)
            } catch {
                // The in-memory refresh still succeeded and must not fail
                // because of this — but if disk still holds the old refresh
                // token, the next launch reads a grant the server has
                // already invalidated and silently drops out of the OAuth
                // path. Surface it so that's diagnosable.
                OAuthFlow.log.error("failed to persist rotated OAuth session: \(String(describing: error), privacy: .public)")
            }
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
