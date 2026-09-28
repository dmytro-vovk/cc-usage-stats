import Darwin
import Network
import XCTest
@testable import CCUsageStats

/// Exercises `LoopbackRedirectListener` in-process, without a browser.
///
/// Tests (b) and (d) are the important ones: they prove the listener's core
/// invariant — a connection that never delivers a well-formed callback must
/// never abort the wait. Browsers open speculative preconnect sockets, and
/// (post-review) a local process could otherwise probe with the wrong path
/// to force a resolution. Only a well-formed callback to the exact redirect
/// path may resolve or fail the wait; everything else must leave it pending
/// until either a real callback arrives or the timeout fires.
final class LoopbackRedirectListenerTests: XCTestCase {
    /// Actor-guarded flag recording whether an `observedWaitTask` has
    /// returned (successfully or not) yet. Reading it after a short sleep
    /// is how a test proves "the wait has not resolved" without racing
    /// `Task.result`/`.value` directly: those do not honor cancellation of
    /// the awaiting context, so a `withTaskGroup` built to "race" one of
    /// them against a timeout can't actually return early — it still has
    /// to wait for the raced task itself to finish before the group
    /// completes, which defeats the entire point of the race.
    private actor ResolvedFlag {
        private(set) var isResolved = false
        func markResolved() { isResolved = true }
    }

    /// Wraps `listener.waitForCallback` in a `Task` that records into
    /// `flag` once the call returns, whether by success or by throwing.
    /// Callers sleep a short interval and then read `flag.isResolved` to
    /// assert "still pending" — no racing of the task itself required.
    private func observedWaitTask(
        _ listener: LoopbackRedirectListener,
        timeout: TimeInterval,
        flag: ResolvedFlag
    ) -> Task<LoopbackRedirectListener.Callback, Error> {
        Task {
            do {
                let result = try await listener.waitForCallback(timeout: timeout)
                await flag.markResolved()
                return result
            } catch {
                await flag.markResolved()
                throw error
            }
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

    /// Opens a raw TCP connection to loopback and returns the open socket
    /// without writing or closing anything — the exact shape of a
    /// browser's speculative preconnect socket, which opens a connection
    /// it may never use. Callers are responsible for closing it.
    private func openEmptyConnection(port: UInt16) throws -> Int32 {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw NSError(domain: "LoopbackRedirectListenerTests", code: 1)
        }

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
            Darwin.close(sock)
            throw NSError(domain: "LoopbackRedirectListenerTests", code: 2)
        }
        return sock
    }

    // MARK: - (a) happy path

    func testHappyPathCallbackCarriesCodeAndState() async throws {
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
        let listener = try await LoopbackRedirectListener.start()
        defer { listener.stop() }
        let port = listener.port

        let flag = ResolvedFlag()
        let waitTask = observedWaitTask(listener, timeout: 5, flag: flag)

        // A well-formed HTTP request, but not a callback: wrong path, no
        // code/state. This is the shape of a browser's speculative
        // preconnect probe (or worse, a hostile local process trying to
        // force a resolution) — it must not resolve or fail the wait.
        try sendRaw("GET / HTTP/1.1\r\n\r\n", port: port)

        // Give the listener ample time to have processed the request and
        // (if it were buggy) resolved the wait — 300ms is generous for an
        // in-process loopback round trip that should complete in well
        // under a millisecond.
        try await Task.sleep(nanoseconds: 300_000_000)
        let resolvedEarly = await flag.isResolved
        XCTAssertFalse(
            resolvedEarly,
            "a non-callback connection resolved the wait; it must be ignored (fixed by the callback-path check)"
        )

        // The real callback must still be able to resolve the same wait.
        let url = URL(string: "http://127.0.0.1:\(port)/callback?code=A&state=B")!
        _ = try await URLSession.shared.data(from: url)

        let callback = try await waitTask.value
        XCTAssertEqual(callback.code, "A")
        XCTAssertEqual(callback.state, "B")
    }

    // MARK: - (c) timeout

    func testWaitForCallbackTimesOutWithCancelled() async throws {
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

    // MARK: - (d) invariant 2, browser-preconnect shape — a connection that sends nothing at all must not abort the wait

    func testEmptyPreconnectSocketDoesNotAbortWaitThenRealCallbackStillResolves() async throws {
        let listener = try await LoopbackRedirectListener.start()
        defer { listener.stop() }
        let port = listener.port

        let flag = ResolvedFlag()
        let waitTask = observedWaitTask(listener, timeout: 5, flag: flag)

        // Open a connection and send nothing at all — a real browser
        // speculative preconnect socket, as opposed to test (b)'s
        // well-formed-but-wrong-path request. It must not resolve or fail
        // the wait either.
        let preconnectSock = try openEmptyConnection(port: port)
        defer { Darwin.close(preconnectSock) }

        try await Task.sleep(nanoseconds: 300_000_000)
        let resolvedEarly = await flag.isResolved
        XCTAssertFalse(
            resolvedEarly,
            "an empty preconnect socket resolved the wait; it must be ignored"
        )

        // A real callback, on a separate connection, must still resolve
        // the same wait.
        let url = URL(string: "http://127.0.0.1:\(port)/callback?code=A&state=B")!
        _ = try await URLSession.shared.data(from: url)

        let callback = try await waitTask.value
        XCTAssertEqual(callback.code, "A")
        XCTAssertEqual(callback.state, "B")
    }

    /// A browser that shows an error never calls back; cancelling the task
    /// must end the wait at once rather than after the full timeout.
    func testWaitForCallbackEndsWhenItsTaskIsCancelled() async throws {
        let listener = try await LoopbackRedirectListener.start()
        defer { listener.stop() }

        let waitTask = Task { try await listener.waitForCallback(timeout: 60) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let started = Date()
        waitTask.cancel()

        do {
            _ = try await waitTask.value
            XCTFail("a cancelled wait must throw")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "cancel must not wait out the timeout")
    }
}
