import XCTest
@testable import CCUsageStats

/// The `wait` ↔ `settle` handshake behind `LoopbackRedirectListener`, tested
/// with no socket in sight.
///
/// This exists because the equivalent logic previously lived inside the
/// listener, which is only constructible by binding a real port — and this
/// machine cannot bind one at all (see `LoopbackRedirectListenerTests`). So
/// the early-arrival case shipped as a `pendingResult` field plus a reader
/// for it and *nothing that ever wrote it*: the result it existed to rescue
/// was still dropped, the flow still hung, and everything still compiled and
/// went green.
final class LoopbackCallbackGateTests: XCTestCase {
    private func callback(_ code: String) -> LoopbackRedirectListener.Callback {
        .init(code: code, state: "state")
    }

    /// Yields until `condition` holds, so "the waiter has registered" is
    /// established rather than assumed. Fails rather than spinning forever.
    private func spinUntil(
        _ condition: () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail(message, file: file, line: line)
    }

    /// The ordinary case: somebody is already waiting when the callback lands.
    func testAWaiterIsResumedWithTheResult() async throws {
        let gate = LoopbackCallbackGate()

        let waiter = Task { try await gate.wait() }
        await spinUntil({ gate.hasWaiter }, "the waiter never registered")
        gate.settle(.success(callback("A")))

        let result = try await waiter.value
        XCTAssertEqual(result.code, "A")
        XCTAssertFalse(gate.hasStashedResult, "a delivered result must not also be stashed")
    }

    /// The case with no coverage before, and the reason this type exists.
    ///
    /// `newConnectionHandler` is installed in `LoopbackRedirectListener.start()`,
    /// before the browser is opened, so a callback can be fully parsed before
    /// the flow gets around to waiting for it. Dropping it is not merely
    /// lossy: the gate is already settled, so the timeout's own `settle` is
    /// ignored too and the wait can never be resumed in either direction —
    /// the connect flow hangs until the app quits.
    func testAResultArrivingBeforeAnyWaiterIsNotDropped() async throws {
        let gate = LoopbackCallbackGate()

        gate.settle(.success(callback("EARLY")))
        XCTAssertFalse(gate.hasWaiter)
        XCTAssertTrue(gate.hasStashedResult, "nothing kept the result for the waiter to come")

        let result = try await gate.wait()
        XCTAssertEqual(result.code, "EARLY", "a callback parsed before the wait began was dropped")
    }

    /// The same path for the failure direction, so a stashed failure cannot
    /// hang the waiter either.
    func testAFailureArrivingBeforeAnyWaiterIsAlsoDelivered() async {
        let gate = LoopbackCallbackGate()

        gate.settle(.failure(OAuthFlow.FlowError.cancelled))

        do {
            _ = try await gate.wait()
            XCTFail("expected the stashed failure")
        } catch let error as OAuthFlow.FlowError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("expected FlowError.cancelled, got \(error)")
        }
    }

    /// The timeout is armed unconditionally by `waitForCallback`, so it fires
    /// after a successful callback in every completed flow. Resuming a
    /// continuation twice traps, so "first result wins" is a hard requirement,
    /// not a nicety.
    func testOnlyTheFirstResultCounts() async throws {
        let gate = LoopbackCallbackGate()

        gate.settle(.success(callback("FIRST")))
        gate.settle(.failure(OAuthFlow.FlowError.cancelled))
        gate.settle(.success(callback("SECOND")))

        let result = try await gate.wait()
        XCTAssertEqual(result.code, "FIRST")
    }

    /// Same rule, with the waiter already registered — the shape a real
    /// timeout-after-success takes.
    func testATimeoutAfterASuccessfulCallbackIsIgnored() async throws {
        let gate = LoopbackCallbackGate()

        let waiter = Task { try await gate.wait() }
        await spinUntil({ gate.hasWaiter }, "the waiter never registered")
        gate.settle(.success(callback("A")))
        gate.settle(.failure(OAuthFlow.FlowError.cancelled))

        let delivered = try await waiter.value
        XCTAssertEqual(delivered.code, "A")
    }
}
