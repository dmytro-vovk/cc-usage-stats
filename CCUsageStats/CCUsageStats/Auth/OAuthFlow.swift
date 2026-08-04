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
/// The loopback redirect is the only supported path. Claude also documents a
/// manual `https://platform.claude.com/oauth/code/callback` redirect, but no
/// paste-the-code UI exists here: binding an ephemeral loopback port does not
/// fail in practice, and a second redirect path would be an untested branch.
/// If `listenerFailed` ever surfaces in the wild, build the manual path then.
enum OAuthFlow {
    // `nonisolated`: the module defaults new declarations to MainActor
    // isolation, but `Logger` is Sendable and this is read from the plain
    // (non-MainActor) `OAuthTokenProvider` actor below — without this the
    // access would need to hop actors just to write a log line.
    nonisolated fileprivate static let log = Logger(subsystem: "dev.dv.ccusagestats", category: "oauth")

    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeEndpoint = "https://claude.com/cai/oauth/authorize"
    static let tokenEndpoint = "https://platform.claude.com/v1/oauth/token"
    static let scope = "user:profile"

    /// `scope` split into the list form a token response reports. Handed to
    /// the initial-grant decoder so an omitted `scope` member resolves to
    /// what was actually requested — see `OAuthSession.fromTokenResponse`.
    static var requestedScopes: [String] { scope.split(separator: " ").map(String.init) }

    /// The loopback redirect handed to the authorization server, for a
    /// listener already bound on `port`.
    ///
    /// The literal `127.0.0.1`, never `localhost`: the listener binds IPv4
    /// only (`.hostPort(host: .ipv4(.loopback), …)`), while `localhost` also
    /// resolves to `::1`, which browsers commonly try first and which nothing
    /// here is listening on. RFC 8252 §8.3 recommends the literal address for
    /// exactly this reason.
    static func redirectURI(port: UInt16) -> String {
        "http://127.0.0.1:\(port)\(LoopbackRedirectListener.callbackPath)"
    }

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
        return try await post(
            body: body,
            decoding: .initialGrant(requestedScopes: requestedScopes),
            session: session,
            now: now
        )
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
        return try await post(
            body: body,
            decoding: .refresh(previous: existing),
            session: session,
            now: now
        )
    }

    /// Which of the two token-response readings applies. They differ in what
    /// an *absent* field means, and only the caller knows which exchange it
    /// just performed, so the choice is made here rather than sniffed from
    /// the response body.
    private enum Decoding {
        /// Authorization-code exchange. An omitted `scope` means the granted
        /// scope equals `requestedScopes` (RFC 6749 §5.1).
        case initialGrant(requestedScopes: [String])
        /// Refresh. An omitted `scope` or `refresh_token` carries forward
        /// from `previous` (RFC 6749 §5.1 and §6).
        case refresh(previous: OAuthSession)
    }

    private static func post(
        body: [String: Any],
        decoding: Decoding,
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
        let decoded: OAuthSession?
        switch decoding {
        case .initialGrant(let requestedScopes):
            decoded = OAuthSession.fromTokenResponse(
                data, now: now, requestedScopes: requestedScopes
            )
        case .refresh(let previous):
            decoded = OAuthSession.fromRefreshResponse(data, now: now, previous: previous)
        }
        guard let decoded else {
            throw FlowError.malformedTokenResponse
        }
        return decoded
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
        let redirectURI = redirectURI(port: listener.port)

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

/// The `wait` ↔ `settle` handshake behind `LoopbackRedirectListener`, split
/// out into a type with no socket in it.
///
/// Split out because it could not otherwise be tested. `LoopbackRedirectListener`
/// is only constructible by binding a real port, so on any machine that
/// cannot bind (see `LoopbackRedirectListenerTests`) this logic has no
/// coverage at all — which is how a half-finished version of it shipped: the
/// listener grew a `pendingResult` field and a reader for it, and nothing
/// anywhere ever wrote it. The early-arrival case it was added for was still
/// dropped, silently, and everything compiled.
///
/// `nonisolated` / `@unchecked Sendable`: `wait` runs on the caller's task
/// (which need not be `@MainActor`), `settle` runs from `.main` — an
/// `NWConnection` receive handler or the timeout — with no synchronization
/// the type system can see between them. `lock` is what earns the
/// `Sendable` claim: every stored var below is read and written only while
/// holding it.
nonisolated final class LoopbackCallbackGate: @unchecked Sendable {
    typealias Callback = LoopbackRedirectListener.Callback

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Callback, Error>?
    private var settled = false
    /// A result that arrived before anyone was waiting for it.
    ///
    /// `newConnectionHandler` is installed in `LoopbackRedirectListener.start()`,
    /// before the browser is opened, so a callback can — barely, but can — be
    /// fully parsed before `wait` registers its continuation. Dropping that
    /// result would be fatal rather than merely lossy: `settled` is already
    /// true, so the timeout's `settle` returns early and the wait never
    /// resumes at all, in either direction. Stash it instead, and hand it to
    /// the first caller of `wait`.
    private var pending: Result<Callback, Error>?

    /// Whether a caller is currently suspended in `wait`, and whether a
    /// result is stashed waiting for one. Exposed only so tests can tell the
    /// two delivery paths apart — settling before versus after a waiter
    /// registers takes different branches, and without this a test can only
    /// sleep and hope it hit the one it meant to.
    var hasWaiter: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }

    var hasStashedResult: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending != nil
    }

    /// Suspends until `settle` is called — or returns straight away when it
    /// already has been.
    ///
    /// Single-shot, like the listener that owns it: a *second* `wait` after
    /// the gate has settled and its result been taken registers a
    /// continuation nothing will ever resume. Unreachable today —
    /// `runInteractive` waits exactly once — and left that way rather than
    /// grown a second timeout path that nothing exercises.
    func wait() async throws -> Callback {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let pending {
                self.pending = nil
                lock.unlock()
                cont.resume(with: pending)
                return
            }
            continuation = cont
            lock.unlock()
        }
    }

    /// Delivers the first result; every later one is ignored, so a timeout
    /// firing after a successful callback (or a second callback) cannot
    /// double-resume the continuation.
    func settle(_ result: Result<Callback, Error>) {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        settled = true
        let cont = continuation
        continuation = nil
        if cont == nil { pending = result }
        lock.unlock()
        // Resumed outside the lock: `CheckedContinuation.resume` can
        // synchronously run the awaiting task's next step, and that step
        // must not re-enter a method that takes this same lock.
        cont?.resume(with: result)
    }
}

/// Single-shot loopback HTTP listener for the OAuth redirect.
/// Construct with `await LoopbackRedirectListener.start()`.
///
/// `nonisolated`: every handler below already runs on `DispatchQueue.main`
/// by construction — the listener is started with `queue: .main` and every
/// accepted connection is too — but that is a fact about *scheduling*, not
/// actor isolation the compiler can verify. Rather than paper over that with
/// an `@MainActor` annotation the framework's `@Sendable` handler closures
/// (in particular `NWListener.newConnectionHandler`) can't actually honor
/// without an async hop, this class opts out of the module's default actor
/// isolation and protects its shared mutable state explicitly — real
/// synchronization instead of an assumption.
///
/// `@unchecked Sendable`: the framework's handler closures are themselves
/// `@Sendable` and capture `self`, so the type must claim `Sendable` to be
/// captured there at all. What earns the claim is that all of its mutable
/// state is guarded: `openConnections` by `stateLock`, and the
/// wait/resolve handshake by `LoopbackCallbackGate`'s own lock.
nonisolated final class LoopbackRedirectListener: @unchecked Sendable {
    struct Callback { let code: String; let state: String }

    /// The only path treated as the OAuth redirect — must match the path
    /// `OAuthFlow.redirectURI` builds into the redirect URI. Any other path
    /// (or a connection that never completes a request) falls into the same
    /// non-fatal 404 bucket as a browser's speculative preconnect socket: it
    /// does not resolve or fail the wait.
    ///
    /// This filters stray traffic — preconnect sockets, port scanners, a
    /// mistyped URL — and nothing more. It is NOT a security boundary: any
    /// local process can send `GET /callback?code=x&state=y` and force a
    /// `.stateMismatch`, aborting the user's authorization. The `state`
    /// check in `runInteractive` is what stops such a request from being
    /// *accepted*; nothing here stops it from being disruptive.
    static let callbackPath = "/callback"

    /// Header terminator; a request is not parsed until this has been
    /// seen, since a single `receive` call only returns whatever arrived
    /// in the first TCP segment — treating that as a complete request line
    /// truncates any request split across segments.
    private static let headerTerminator = Data("\r\n\r\n".utf8)
    /// Hard cap on buffered request bytes, so a connection that dribbles
    /// bytes forever without ever completing its headers still gets a
    /// response (and cancellation) instead of buffering indefinitely.
    private static let maxRequestBytes = 8192

    private let listener: NWListener
    /// The wait/resolve handshake. Owns its own lock; see
    /// `LoopbackCallbackGate`.
    private let gate = LoopbackCallbackGate()
    /// Guards `openConnections`, which is touched from `.main` callbacks and
    /// from `stop()`, which callers may invoke from off `.main` (it runs
    /// synchronously via `defer` in `runInteractive`).
    private let stateLock = NSLock()
    /// Every connection accepted while waiting for the callback, so
    /// `stop()` can cancel the ones that never sent a complete (or any)
    /// request. `listener.cancel()` alone does not touch already-accepted
    /// connections, and a speculative preconnect socket that never sends
    /// anything would otherwise leak an `NWConnection` for the process's
    /// remaining lifetime.
    private var openConnections: [ObjectIdentifier: NWConnection] = [:]
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

        let instance = LoopbackRedirectListener(listener: l, port: port)
        // Installed here rather than in `waitForCallback`: the listener has
        // been accepting connections since `l.start(queue:)` above, and the
        // caller opens the browser before it starts waiting. A connection
        // accepted in that window used to have no handler at all.
        l.newConnectionHandler = { [weak instance] conn in
            instance?.handle(conn)
        }
        return instance
    }

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    func waitForCallback(timeout: TimeInterval) async throws -> Callback {
        // Armed before the wait rather than from inside it: if the callback
        // has already arrived, `gate.wait()` returns immediately and this
        // late `.cancelled` is ignored by the gate. Capturing `gate` rather
        // than `[weak self]` means the timeout still fires — and the waiter
        // still gets an answer — even if the listener itself is gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [gate] in
            gate.settle(.failure(OAuthFlow.FlowError.cancelled))
        }
        return try await gate.wait()
    }

    private func handle(_ conn: NWConnection) {
        stateLock.lock()
        openConnections[ObjectIdentifier(conn)] = conn
        stateLock.unlock()
        conn.start(queue: .main)
        receiveRequest(conn, buffer: Data())
    }

    /// Accumulates bytes across as many `receive` calls as needed until the
    /// header terminator is seen, the byte cap is hit, or the connection
    /// itself signals completion/error — a single segment is not assumed
    /// to be a complete HTTP request.
    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            let haveHeaders = buffer.range(of: Self.headerTerminator) != nil
            let gaveUp = buffer.count >= Self.maxRequestBytes || isComplete || error != nil

            guard haveHeaders || gaveUp else {
                self.receiveRequest(conn, buffer: buffer)
                return
            }

            self.respond(conn, buffer: buffer)
        }
    }

    private func respond(_ conn: NWConnection, buffer: Data) {
        let request = String(data: buffer, encoding: .utf8) ?? ""

        let parsed: Callback? = {
            guard let line = request.split(separator: "\r\n").first,
                  let pathPart = line.split(separator: " ").dropFirst().first,
                  let comps = URLComponents(string: "http://localhost\(pathPart)"),
                  comps.path == Self.callbackPath,
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
        let id = ObjectIdentifier(conn)
        conn.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            conn.cancel()
            guard let self else { return }
            self.stateLock.lock()
            self.openConnections.removeValue(forKey: id)
            self.stateLock.unlock()
        })

        // Only a well-formed callback to the exact redirect path ends the
        // wait. Browsers open speculative preconnect sockets that carry no
        // request at all, and any other stray probe (wrong path, wrong or
        // missing state) would otherwise abort an in-progress
        // authorization. Failure comes from the timeout alone.
        if let parsed { self.finish(.success(parsed)) }
    }

    private func finish(_ result: Result<Callback, Error>) {
        gate.settle(result)
    }

    func stop() {
        listener.cancel()
        // `listener.cancel()` does not touch already-accepted connections;
        // cancel every one still open (never sent a complete request, or
        // its response send completion hasn't run yet) so none outlive the
        // flow.
        stateLock.lock()
        let toCancel = Array(openConnections.values)
        openConnections.removeAll()
        stateLock.unlock()
        for conn in toCancel { conn.cancel() }
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
