import Foundation

/// Whether this process is a test run.
///
/// The unit bundle is hosted *in the app*, so `xcodebuild test` launches real
/// app instances that run `@main` init and the view model's `start()`. With no
/// signal to key off, those instances read and rewrite the user's own state:
/// the Keychain token, `history.jsonl`, and (on a machine that hasn't migrated
/// yet) `~/.claude/settings.json`. Running the suite must never do that, so
/// every path into user state consults this and redirects to a scratch
/// location instead.
///
/// Resolved once, from the process itself, rather than passed in by callers —
/// an isolation scheme that depends on each test remembering to opt in stops
/// being true the first time someone adds a test.
enum TestEnvironment {
    /// True inside `xcodebuild test` (the env var) and inside any process with
    /// XCTest loaded (the class lookup). Both signals, because the app is the
    /// test host and neither alone covers every launch path.
    static let isRunningTests: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    /// Suffix that keeps one test worker's scratch state away from another's.
    ///
    /// `xcodebuild` runs the suite across several host processes at once, so a
    /// single shared scratch name is a race: one worker's `tearDown` deletes
    /// the Keychain item another worker is mid-assertion on, and parallel
    /// appends to one `history.jsonl` interleave. Per-process names make the
    /// workers invisible to each other.
    static let scratchSuffix: String = String(ProcessInfo.processInfo.processIdentifier)
}
