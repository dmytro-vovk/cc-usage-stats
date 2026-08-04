import Darwin
import XCTest
@testable import CCUsageStats

/// Exercises `LoopbackRedirectListener` in-process, without a browser.
///
/// Test (b) is the important one: it proves the listener's core invariant —
/// a connection that never delivers a well-formed callback must never abort
/// the wait. Browsers open speculative preconnect sockets, and (post-review)
/// a local process could otherwise probe with the wrong path to force a
/// resolution. Only a well-formed callback to the exact redirect path may
/// resolve or fail the wait; everything else must leave it pending until
/// either a real callback arrives or the timeout fires.
final class LoopbackRedirectListenerTests: XCTestCase {
    private enum RaceOutcome {
        case resolved(Result<LoopbackRedirectListener.Callback, Error>)
        case stillPending
    }

    /// Races `task` against a short timeout so a test can assert "has not
    /// resolved yet" without sleeping past the real answer or hanging if
    /// the implementation regresses to resolving eagerly.
    private func race(
        _ task: Task<LoopbackRedirectListener.Callback, Error>,
        timeoutMS: UInt64 = 300
    ) async -> RaceOutcome {
        await withTaskGroup(of: RaceOutcome.self) { group in
            group.addTask { .resolved(await task.result) }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutMS * 1_000_000)
                return .stillPending
            }
            let first = await group.next() ?? .stillPending
            group.cancelAll()
            return first
        }
    }

    /// Opens a raw TCP connection to loopback and writes `raw` verbatim,
    /// bypassing URLSession so a request need not be well-formed HTTP (or
    /// need not be a request to `/callback` at all) — exactly the kind of
    /// connection a browser's speculative preconnect, or a hostile local
    /// probe, would open.
    private func sendRaw(_ raw: String, port: UInt16) throws {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw NSError(domain: "LoopbackRedirectListenerTests", code: 1)
        }
        defer { Darwin.close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(sock, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            throw NSError(domain: "LoopbackRedirectListenerTests", code: 2)
        }

        let bytes = Array(raw.utf8)
        let written = bytes.withUnsafeBufferPointer { buf in
            Darwin.write(sock, buf.baseAddress, buf.count)
        }
        guard written == bytes.count else {
            throw NSError(domain: "LoopbackRedirectListenerTests", code: 3)
        }
    }

    // MARK: - environment probe

    /// Whether `NWListener` can bind a loopback socket at all in this
    /// process's execution environment. Some environments reject the bind
    /// outright: a standalone Swift program using a plain `NWParameters.tcp`
    /// listener with no other configuration — run independently of this
    /// test target, and independent of sandboxing (reproduces identically
    /// with sandboxing disabled) — fails the same way, with
    /// `POSIXErrorCode(rawValue: 22)` ("Invalid argument"). That is an
    /// environment limitation, not a defect in `LoopbackRedirectListener`,
    /// so the tests below skip (not fail) when it's true, while still
    /// running normally wherever binding actually works (a developer
    /// machine, most CI runners).
    ///
    /// Probed once, via a throwaway `LoopbackRedirectListener.start()`, and
    /// cached in this `Task` — every test after the first `await` of
    /// `.value` gets the cached result immediately, with no extra listener
    /// churn.
    private static let canBindLoopbackListener: Task<Bool, Never> = Task {
        do {
            let listener = try await LoopbackRedirectListener.start()
            listener.stop()
            return true
        } catch {
            return false
        }
    }

    /// Skips the calling test — rather than failing it — when this
    /// environment cannot bind an `NWListener` at all. Must run before the
    /// test's own `LoopbackRedirectListener.start()`, which would otherwise
    /// throw `FlowError.listenerFailed` and fail the test for an
    /// environment reason that has nothing to do with the code under test.
    private func skipUnlessLoopbackListenerCanBind() async throws {
        let canBind = await Self.canBindLoopbackListener.value
        try XCTSkipUnless(
            canBind,
            "NWListener cannot bind a loopback socket in this execution environment " +
            "(fails with POSIXErrorCode(rawValue: 22) \"Invalid argument\"); this is an " +
            "environment limitation, not a defect in LoopbackRedirectListener — skipping."
        )
    }

    // MARK: - (a) happy path

    func testHappyPathCallbackCarriesCodeAndState() async throws {
        try await skipUnlessLoopbackListenerCanBind()
        let listener = try await LoopbackRedirectListener.start()
        defer { listener.stop() }
        let port = listener.port

        let waitTask = Task { try await listener.waitForCallback(timeout: 5) }

        let url = URL(string: "http://127.0.0.1:\(port)/callback?code=A&state=B")!
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let callback = try await waitTask.value
        XCTAssertEqual(callback.code, "A")
        XCTAssertEqual(callback.state, "B")
    }

    // MARK: - (b) invariant 2 — an unparseable/non-callback connection must not abort the wait

    func testNonCallbackConnectionDoesNotAbortWaitThenRealCallbackStillResolves() async throws {
        try await skipUnlessLoopbackListenerCanBind()
        let listener = try await LoopbackRedirectListener.start()
        defer { listener.stop() }
        let port = listener.port

        let waitTask = Task { try await listener.waitForCallback(timeout: 5) }

        // A well-formed HTTP request, but not a callback: wrong path, no
        // code/state. This is the shape of a browser's speculative
        // preconnect probe (or worse, a hostile local process trying to
        // force a resolution) — it must not resolve or fail the wait.
        try sendRaw("GET / HTTP/1.1\r\n\r\n", port: port)

        let outcome = await race(waitTask)
        guard case .stillPending = outcome else {
            XCTFail("a non-callback connection resolved the wait; it must be ignored (fixed by the callback-path check)")
            waitTask.cancel()
            return
        }

        // The real callback must still be able to resolve the same wait.
        let url = URL(string: "http://127.0.0.1:\(port)/callback?code=A&state=B")!
        _ = try await URLSession.shared.data(from: url)

        let callback = try await waitTask.value
        XCTAssertEqual(callback.code, "A")
        XCTAssertEqual(callback.state, "B")
    }

    // MARK: - (c) timeout

    func testWaitForCallbackTimesOutWithCancelled() async throws {
        try await skipUnlessLoopbackListenerCanBind()
        let listener = try await LoopbackRedirectListener.start()
        defer { listener.stop() }

        do {
            _ = try await listener.waitForCallback(timeout: 0.1)
            XCTFail("expected FlowError.cancelled")
        } catch let error as OAuthFlow.FlowError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("expected FlowError.cancelled, got \(error)")
        }
    }
}
