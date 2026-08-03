# Per-Model Weekly Usage Meter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the per-model weekly rate-limit window (the "Fable" meter in Claude Code's `/usage` panel) in both the menubar pill and the dropdown, alongside the existing 5-hour and 7-day windows.

**Architecture:** The per-model window is not in the response headers the current poller scrapes — it only exists at `GET https://api.anthropic.com/api/oauth/usage`, which requires the `user:profile` OAuth scope. This plan adds a PKCE OAuth flow to obtain a scoped token, a second poller client for that endpoint, and keeps the existing header client as a fallback so un-migrated tokens keep working. Model windows are enumerated from whatever `seven_day_*` keys arrive rather than hardcoding a model name.

**Tech Stack:** Swift 5 / SwiftUI / AppKit, XCTest, CryptoKit (SHA256 for PKCE), Network.framework (`NWListener` for the loopback redirect), macOS 13.5 deployment target.

## Global Constraints

- Deployment target is `MACOSX_DEPLOYMENT_TARGET=13.5`. Do not use APIs newer than macOS 13.5.
- The Xcode project uses `fileSystemSynchronizedGroups`. **New `.swift` files are picked up automatically — do not edit `project.pbxproj`.** Place app files under `CCUsageStats/CCUsageStats/<Group>/` and test files under `CCUsageStats/CCUsageStatsTests/`.
- Spec: `docs/superpowers/specs/2026-07-27-fable-usage-meter-design.md`.
- **Base commit: `a9f3bf7`.** This plan was rebased onto it after parallel token-recovery work landed. Four facts from that work the plan depends on:
  - `AuthState` gained `.noToken` (nothing stored) as distinct from `.invalidToken` (API rejected it), plus `var lacksWorkingToken: Bool`. It is now `CaseIterable` with exhaustiveness tests — **use `lacksWorkingToken`, never `== .invalidToken`,** when the question is "can we poll at all".
  - `TokenStore.serviceName` is a computed `static var` that redirects to a per-process scratch name under test (`TestEnvironment`). Anything storing in Keychain under that service inherits test isolation for free.
  - `MenuViewModel` takes an injected `apiFactory` and shares one `attachPoller(token:)` between `start()` and `restartPolling()`. Do not reintroduce a second copy of that wiring.
  - `TestEnvironment.isRunningTests` makes `start()` a no-op under test. View-model tests drive the state machine directly.
- OAuth constants, verbatim:
  - `client_id` = `9d1c250a-e61b-44d9-88ed-5944d1962f5e`
  - authorize = `https://claude.com/cai/oauth/authorize`
  - token = `https://platform.claude.com/v1/oauth/token` (**JSON body**, `Content-Type: application/json` — not form-encoded)
  - manual redirect = `https://platform.claude.com/oauth/code/callback`
  - scope requested = `user:profile` only
  - PKCE method = `S256`
- Usage endpoint = `GET https://api.anthropic.com/api/oauth/usage`, header `Authorization: Bearer <accessToken>`.
- Wire format differences that must be honored at the parse boundary:
  - `/api/oauth/usage` `utilization` is **percent (0–100)**; the headers give a **fraction (0–1)**. Internal `WindowSnapshot.usedPercentage` is percent, so the endpoint value passes through **unscaled**.
  - `/api/oauth/usage` `resets_at` is an **ISO 8601 string**; the headers give **epoch seconds**.
- Denylisted keys, never rendered as model windows: `seven_day_oauth_apps`, `cinder_cove`, `extra_usage`.
- Never commit without the user's explicit approval (project rule). Each "Commit" step below stages and writes the commit; if running unattended, stage and stop.
- Commit messages end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

---

## File Structure

**Create:**

| File | Responsibility |
|---|---|
| `scripts/test.sh` | One-line test invocation used by every task below |
| `CCUsageStats/CCUsageStats/Core/UsageWindows.swift` | Pure key classification, label derivation, render ordering |
| `CCUsageStats/CCUsageStats/Poller/OAuthUsage.swift` | Pure parser for the usage endpoint response |
| `CCUsageStats/CCUsageStats/Poller/OAuthUsageClient.swift` | Live `GET` client for the usage endpoint |
| `CCUsageStats/CCUsageStats/Auth/PKCE.swift` | Verifier / challenge derivation |
| `CCUsageStats/CCUsageStats/Auth/OAuthSession.swift` | Session value type + Keychain persistence |
| `CCUsageStats/CCUsageStats/Auth/OAuthFlow.swift` | Authorize URL, loopback listener, code exchange, refresh |
| `CCUsageStats/CCUsageStats/Tray/PillLayout.swift` | Pure segment selection for the menubar pill |
| `CCUsageStats/CCUsageStats/Tray/MenuBarPillRenderer.swift` | N-segment NSImage rendering, extracted from `MenuBarContent` |

**Modify:**

| File | Change |
|---|---|
| `CCUsageStats/CCUsageStats/Core/RateLimits.swift` | Add `models` to `RateLimitsSnapshot` |
| `CCUsageStats/CCUsageStats/Core/CacheStore.swift` | Persist + per-key merge `model_windows` |
| `CCUsageStats/CCUsageStats/Poller/AnthropicAPI.swift` | Add `.insufficientScope` result case |
| `CCUsageStats/CCUsageStats/Poller/UsagePoller.swift` | Fallback client, `needsReauthorization` |
| `CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift` | Delegate rendering, add model dropdown rows |
| `CCUsageStats/CCUsageStats/Tray/MenuViewModel.swift` | Teach `attachPoller` the dual path, expose reauth state |
| `CCUsageStats/CCUsageStats/Auth/SettingsWindow.swift` | "Connect Claude account" button |
| `README.md`, `docs/manual-test-checklist.md` | Document the new meter and flow |

---

### Task 1: Model windows in the snapshot and cache

**Files:**
- Create: `scripts/test.sh`
- Modify: `CCUsageStats/CCUsageStats/Core/RateLimits.swift`
- Modify: `CCUsageStats/CCUsageStats/Core/CacheStore.swift`
- Test: `CCUsageStats/CCUsageStatsTests/CacheStoreTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `RateLimitsSnapshot(fiveHour:sevenDay:models:)` where `models` is `[String: WindowSnapshot]` defaulting to `[:]`. Every later task constructs snapshots through this initializer.

- [ ] **Step 1: Add the test runner script**

Create `scripts/test.sh`:

```bash
#!/usr/bin/env bash
# Runs the unit-test bundle. Pass an optional -only-testing target, e.g.
#   scripts/test.sh CCUsageStatsTests/CacheStoreTests/testModelWindowsRoundTrip
set -euo pipefail
cd "$(dirname "$0")/.."

ONLY=()
if [ $# -gt 0 ]; then ONLY=(-only-testing:"$1"); else ONLY=(-only-testing:CCUsageStatsTests); fi

xcodebuild test \
  -scheme CCUsageStats \
  -destination 'platform=macOS' \
  -project CCUsageStats/CCUsageStats.xcodeproj \
  "${ONLY[@]}" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  MACOSX_DEPLOYMENT_TARGET=13.5
```

Then: `chmod +x scripts/test.sh`

- [ ] **Step 2: Write the failing tests**

Append to `CCUsageStats/CCUsageStatsTests/CacheStoreTests.swift` (inside the existing `final class CacheStoreTests: XCTestCase`, which is annotated `@MainActor` — do not re-annotate the new methods):

```swift
func testModelWindowsRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cc-usage-model-roundtrip-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let snap = RateLimitsSnapshot(
        fiveHour: WindowSnapshot(usedPercentage: 10, resetsAt: 100),
        sevenDay: WindowSnapshot(usedPercentage: 20, resetsAt: 200),
        models: ["seven_day_fable": WindowSnapshot(usedPercentage: 93, resetsAt: 300)]
    )
    try CacheStore.update(at: url, with: snap, now: 42)

    let read = try XCTUnwrap(CacheStore.read(at: url))
    XCTAssertEqual(read.snapshot.models["seven_day_fable"]?.usedPercentage, 93)
    XCTAssertEqual(read.snapshot.models["seven_day_fable"]?.resetsAt, 300)
}

func testOldFormatFileDecodesWithEmptyModels() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cc-usage-oldformat-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    // Exactly the shape written by versions before this feature.
    let legacy = """
    {"captured_at":42,"five_hour":{"used_percentage":10,"resets_at":100}}
    """
    try Data(legacy.utf8).write(to: url)

    let read = try XCTUnwrap(CacheStore.read(at: url))
    XCTAssertEqual(read.snapshot.fiveHour?.usedPercentage, 10)
    XCTAssertTrue(read.snapshot.models.isEmpty)
}

func testModelWindowsMergePerKey() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cc-usage-model-merge-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    try CacheStore.update(at: url, with: RateLimitsSnapshot(
        fiveHour: nil, sevenDay: nil,
        models: [
            "seven_day_fable": WindowSnapshot(usedPercentage: 50, resetsAt: 1),
            "seven_day_sonnet": WindowSnapshot(usedPercentage: 60, resetsAt: 2),
        ]
    ), now: 1)

    // A later poll returns only one of the two keys.
    try CacheStore.update(at: url, with: RateLimitsSnapshot(
        fiveHour: nil, sevenDay: nil,
        models: ["seven_day_fable": WindowSnapshot(usedPercentage: 55, resetsAt: 3)]
    ), now: 2)

    let read = try XCTUnwrap(CacheStore.read(at: url))
    XCTAssertEqual(read.snapshot.models["seven_day_fable"]?.usedPercentage, 55)
    XCTAssertEqual(read.snapshot.models["seven_day_sonnet"]?.usedPercentage, 60,
                   "absent keys must preserve the on-disk value")
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `scripts/test.sh CCUsageStatsTests/CacheStoreTests`

Expected: FAIL — compile error, `extra argument 'models' in call`.

- [ ] **Step 4: Add `models` to the snapshot**

Replace the `RateLimitsSnapshot` declaration in `CCUsageStats/CCUsageStats/Core/RateLimits.swift`:

```swift
/// The rate-limit windows cached for the menubar UI.
struct RateLimitsSnapshot: Codable, Equatable {
    let fiveHour: WindowSnapshot?
    let sevenDay: WindowSnapshot?
    /// Per-model weekly windows, keyed by their wire key (e.g.
    /// "seven_day_fable"). Only populated by the /api/oauth/usage path;
    /// the response-header path cannot see these windows at all.
    let models: [String: WindowSnapshot]

    init(
        fiveHour: WindowSnapshot?,
        sevenDay: WindowSnapshot?,
        models: [String: WindowSnapshot] = [:]
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.models = models
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case models = "model_windows"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try c.decodeIfPresent(WindowSnapshot.self, forKey: .fiveHour)
        sevenDay = try c.decodeIfPresent(WindowSnapshot.self, forKey: .sevenDay)
        models = try c.decodeIfPresent([String: WindowSnapshot].self, forKey: .models) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(fiveHour, forKey: .fiveHour)
        try c.encodeIfPresent(sevenDay, forKey: .sevenDay)
        if !models.isEmpty { try c.encode(models, forKey: .models) }
    }
}
```

- [ ] **Step 5: Persist and merge model windows in the cache**

In `CCUsageStats/CCUsageStats/Core/CacheStore.swift`, add the coding key, decode it, encode it, and merge per key.

Add to `CachedState.CodingKeys`:

```swift
        case models = "model_windows"
```

Replace `CachedState.init(from:)` body's snapshot construction:

```swift
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = try c.decode(Int64.self, forKey: .capturedAt)
        snapshot = RateLimitsSnapshot(
            fiveHour: try c.decodeIfPresent(WindowSnapshot.self, forKey: .fiveHour),
            sevenDay: try c.decodeIfPresent(WindowSnapshot.self, forKey: .sevenDay),
            models: try c.decodeIfPresent([String: WindowSnapshot].self, forKey: .models) ?? [:]
        )
    }
```

Replace `CachedState.encode(to:)`:

```swift
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(capturedAt, forKey: .capturedAt)
        try c.encodeIfPresent(snapshot.fiveHour, forKey: .fiveHour)
        try c.encodeIfPresent(snapshot.sevenDay, forKey: .sevenDay)
        if !snapshot.models.isEmpty { try c.encode(snapshot.models, forKey: .models) }
    }
```

Replace the merge in `CacheStore.update(at:with:now:)`:

```swift
        let existing = try read(at: url)?.snapshot
        // Per-key merge: a poll that omits a model window must preserve the
        // last known value rather than dropping the row from the dropdown.
        var mergedModels = existing?.models ?? [:]
        for (key, window) in incoming.models { mergedModels[key] = window }
        let merged = RateLimitsSnapshot(
            fiveHour: incoming.fiveHour ?? existing?.fiveHour,
            sevenDay: incoming.sevenDay ?? existing?.sevenDay,
            models: mergedModels
        )
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `scripts/test.sh CCUsageStatsTests`

Expected: PASS — all existing tests plus the three new ones. Existing `RateLimitsSnapshot(fiveHour:sevenDay:)` call sites still compile because `models` defaults to `[:]`.

- [ ] **Step 7: Commit**

```bash
git add scripts/test.sh CCUsageStats/CCUsageStats/Core/RateLimits.swift CCUsageStats/CCUsageStats/Core/CacheStore.swift CCUsageStats/CCUsageStatsTests/CacheStoreTests.swift
git commit -m "feat: carry per-model weekly windows through snapshot and cache

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Window key classification and labels

**Files:**
- Create: `CCUsageStats/CCUsageStats/Core/UsageWindows.swift`
- Test: `CCUsageStats/CCUsageStatsTests/UsageWindowsTests.swift`

**Interfaces:**
- Consumes: `WindowSnapshot` from Task 1.
- Produces: `UsageWindows.isModelKey(_ key: String) -> Bool`, `UsageWindows.label(for key: String) -> String`, `UsageWindows.orderedModelKeys(_ models: [String: WindowSnapshot]) -> [String]`. Tasks 3, 7, and 8 all call these.

- [ ] **Step 1: Write the failing test**

Create `CCUsageStats/CCUsageStatsTests/UsageWindowsTests.swift`:

```swift
import XCTest
@testable import CCUsageStats

final class UsageWindowsTests: XCTestCase {
    func testModelKeyRecognition() {
        XCTAssertTrue(UsageWindows.isModelKey("seven_day_fable"))
        XCTAssertTrue(UsageWindows.isModelKey("seven_day_opus"))
        XCTAssertFalse(UsageWindows.isModelKey("seven_day"))
        XCTAssertFalse(UsageWindows.isModelKey("five_hour"))
    }

    func testDenylistedKeysAreNotModelWindows() {
        XCTAssertFalse(UsageWindows.isModelKey("seven_day_oauth_apps"))
        XCTAssertFalse(UsageWindows.isModelKey("cinder_cove"))
        XCTAssertFalse(UsageWindows.isModelKey("extra_usage"))
    }

    func testLabels() {
        XCTAssertEqual(UsageWindows.label(for: "five_hour"), "5-hour session")
        XCTAssertEqual(UsageWindows.label(for: "seven_day"), "7-day window")
        XCTAssertEqual(UsageWindows.label(for: "seven_day_fable"), "Fable weekly")
        XCTAssertEqual(UsageWindows.label(for: "seven_day_opus"), "Opus weekly")
    }

    func testMultiWordModelKeyLabel() {
        XCTAssertEqual(UsageWindows.label(for: "seven_day_fable_mini"), "Fable Mini weekly")
    }

    func testOrderedModelKeysIsSortedAndFiltered() {
        let models: [String: WindowSnapshot] = [
            "seven_day_sonnet": WindowSnapshot(usedPercentage: 1, resetsAt: 1),
            "seven_day_fable": WindowSnapshot(usedPercentage: 2, resetsAt: 2),
            "seven_day_oauth_apps": WindowSnapshot(usedPercentage: 3, resetsAt: 3),
        ]
        XCTAssertEqual(UsageWindows.orderedModelKeys(models),
                       ["seven_day_fable", "seven_day_sonnet"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh CCUsageStatsTests/UsageWindowsTests`

Expected: FAIL — "cannot find 'UsageWindows' in scope".

- [ ] **Step 3: Write the implementation**

Create `CCUsageStats/CCUsageStats/Core/UsageWindows.swift`:

```swift
import Foundation

/// Classification and labelling for rate-limit window keys as they arrive
/// from `GET /api/oauth/usage`.
///
/// Model keys are enumerated rather than hardcoded: the endpoint has used
/// `seven_day_opus` and `seven_day_sonnet`, and the premium model is
/// renamed periodically. Deriving the label from the wire key means a new
/// model appears without a code change — the label follows the wire.
enum UsageWindows {
    static let modelKeyPrefix = "seven_day_"

    /// Keys that share the `seven_day_` prefix but are not model windows.
    static let denylist: Set<String> = [
        "seven_day_oauth_apps",
        "cinder_cove",
        "extra_usage",
    ]

    static func isModelKey(_ key: String) -> Bool {
        key.hasPrefix(modelKeyPrefix)
            && key != modelKeyPrefix
            && !denylist.contains(key)
    }

    static func label(for key: String) -> String {
        switch key {
        case "five_hour": return "5-hour session"
        case "seven_day": return "7-day window"
        default:
            guard isModelKey(key) else { return key }
            let raw = key.dropFirst(modelKeyPrefix.count)
            let pretty = raw.split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
            return "\(pretty) weekly"
        }
    }

    /// Deterministic render order so the dropdown does not reshuffle
    /// between polls.
    static func orderedModelKeys(_ models: [String: WindowSnapshot]) -> [String] {
        models.keys.filter(isModelKey).sorted()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh CCUsageStatsTests/UsageWindowsTests`

Expected: PASS — 5 tests.

- [ ] **Step 5: Commit**

```bash
git add CCUsageStats/CCUsageStats/Core/UsageWindows.swift CCUsageStats/CCUsageStatsTests/UsageWindowsTests.swift
git commit -m "feat: derive model-window labels from wire keys

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Usage endpoint parser

**Files:**
- Create: `CCUsageStats/CCUsageStats/Poller/OAuthUsage.swift`
- Modify: `CCUsageStats/CCUsageStats/Poller/AnthropicAPI.swift`
- Modify: `CCUsageStats/CCUsageStats/Poller/UsagePoller.swift`
- Modify: `CCUsageStats/CCUsageStats/Auth/SettingsWindow.swift`
- Test: `CCUsageStats/CCUsageStatsTests/OAuthUsageTests.swift`

**Interfaces:**
- Consumes: `UsageWindows.isModelKey` (Task 2), `RateLimitsSnapshot(fiveHour:sevenDay:models:)` (Task 1).
- Produces: `AnthropicAPI.Result.insufficientScope`, `OAuthUsage.parse(status: Int, body: Data) -> AnthropicAPI.Result`, `OAuthUsage.epochSeconds(fromISO8601:) -> Int64?`.

- [ ] **Step 1: Write the failing test**

Create `CCUsageStats/CCUsageStatsTests/OAuthUsageTests.swift`:

```swift
import XCTest
@testable import CCUsageStats

final class OAuthUsageTests: XCTestCase {
    private func body(_ s: String) -> Data { Data(s.utf8) }

    func testUtilizationIsPercentAndNotRescaled() throws {
        let json = """
        {"five_hour":{"utilization":42.5,"resets_at":"2026-07-28T04:00:00Z"}}
        """
        let result = OAuthUsage.parse(status: 200, body: body(json))
        guard case let .success(snap) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(snap.fiveHour!.usedPercentage, 42.5, accuracy: 0.001)
    }

    func testISO8601WithAndWithoutFractionalSeconds() {
        XCTAssertEqual(OAuthUsage.epochSeconds(fromISO8601: "2026-07-28T04:00:00Z"), 1785211200)
        XCTAssertEqual(OAuthUsage.epochSeconds(fromISO8601: "2026-07-28T04:00:00.123Z"), 1785211200)
        XCTAssertNil(OAuthUsage.epochSeconds(fromISO8601: "not a date"))
    }

    func testUnknownModelKeysAreSurfaced() throws {
        let json = """
        {"seven_day_fable":{"utilization":93,"resets_at":"2026-07-28T04:00:00Z"},
         "seven_day_brandnew":{"utilization":12,"resets_at":"2026-07-28T04:00:00Z"}}
        """
        let result = OAuthUsage.parse(status: 200, body: body(json))
        guard case let .success(snap) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(Set(snap.models.keys), ["seven_day_fable", "seven_day_brandnew"])
        XCTAssertEqual(snap.models["seven_day_fable"]!.usedPercentage, 93, accuracy: 0.001)
    }

    func testDenylistedKeysAreDropped() throws {
        let json = """
        {"seven_day":{"utilization":18,"resets_at":"2026-07-28T04:00:00Z"},
         "seven_day_oauth_apps":{"utilization":5,"resets_at":"2026-07-28T04:00:00Z"}}
        """
        let result = OAuthUsage.parse(status: 200, body: body(json))
        guard case let .success(snap) = result else { return XCTFail("got \(result)") }
        XCTAssertTrue(snap.models.isEmpty)
        XCTAssertEqual(snap.sevenDay!.usedPercentage, 18, accuracy: 0.001)
    }

    func testNullUtilizationIsSkipped() throws {
        let json = """
        {"five_hour":{"utilization":10,"resets_at":"2026-07-28T04:00:00Z"},
         "seven_day_fable":{"utilization":null,"resets_at":"2026-07-28T04:00:00Z"}}
        """
        let result = OAuthUsage.parse(status: 200, body: body(json))
        guard case let .success(snap) = result else { return XCTFail("got \(result)") }
        XCTAssertTrue(snap.models.isEmpty)
    }

    func testIntegerUtilizationParses() throws {
        let json = """
        {"five_hour":{"utilization":0,"resets_at":"2026-07-28T04:00:00Z"}}
        """
        let result = OAuthUsage.parse(status: 200, body: body(json))
        guard case let .success(snap) = result else { return XCTFail("got \(result)") }
        XCTAssertEqual(snap.fiveHour!.usedPercentage, 0, accuracy: 0.001)
    }

    func testFieldlessBodyYieldsNotSubscriber() {
        let result = OAuthUsage.parse(status: 200, body: body("{}"))
        if case .notSubscriber = result { return }
        XCTFail("expected .notSubscriber, got \(result)")
    }

    func test403ScopeErrorYieldsInsufficientScope() {
        let json = """
        {"type":"error","error":{"type":"permission_error",
         "message":"OAuth token does not meet scope requirement user:profile"}}
        """
        let result = OAuthUsage.parse(status: 403, body: body(json))
        if case .insufficientScope = result { return }
        XCTFail("expected .insufficientScope, got \(result)")
    }

    func test403WithoutScopeMessageYieldsInvalidToken() {
        let result = OAuthUsage.parse(status: 403, body: body(#"{"error":"forbidden"}"#))
        if case .invalidToken = result { return }
        XCTFail("expected .invalidToken, got \(result)")
    }

    func test401YieldsInvalidToken() {
        let result = OAuthUsage.parse(status: 401, body: Data())
        if case .invalidToken = result { return }
        XCTFail()
    }

    func test429YieldsRateLimited() {
        let result = OAuthUsage.parse(status: 429, body: Data())
        if case .rateLimited = result { return }
        XCTFail()
    }

    func test5xxYieldsTransient() {
        let result = OAuthUsage.parse(status: 503, body: Data())
        if case .transient = result { return }
        XCTFail()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh CCUsageStatsTests/OAuthUsageTests`

Expected: FAIL — "cannot find 'OAuthUsage' in scope".

- [ ] **Step 3: Add the `.insufficientScope` case**

In `CCUsageStats/CCUsageStats/Poller/AnthropicAPI.swift`, add one case to `AnthropicAPI.Result`:

```swift
    enum Result: Equatable {
        case success(RateLimitsSnapshot)
        case invalidToken
        /// Token is valid but lacks `user:profile`, so /api/oauth/usage is
        /// refused. Distinct from `.invalidToken` because the same token
        /// still works on the response-header path.
        case insufficientScope
        case notSubscriber
        case rateLimited
        case transient(String) // network, malformed body, 5xx, 4xx other
    }
```

Do **not** change `AnthropicAPI.parse` — the header path keeps mapping 403 to `.invalidToken`, and `AnthropicAPITests.test403YieldsInvalidToken` must stay green.

- [ ] **Step 4: Handle the new case in BOTH exhaustive switches so the build compiles**

There are exactly two exhaustive switches over `AnthropicAPI.Result` in the app target. Both must be patched or the whole bundle fails to compile. (Tests use `if case`, which does not require exhaustiveness.)

First, `CCUsageStats/CCUsageStats/Poller/UsagePoller.swift:81` — add a case to the `switch result` in `tick()`, directly after the `.invalidToken` case. Task 6 replaces this body with the real fallback logic; for now it must merely compile and not crash.

```swift
        case .insufficientScope:
            // Wired properly in the dual-path work; until then behave like a
            // transient failure so polling continues.
            Self.log.warning("insufficient scope for /api/oauth/usage")
```

Second, `CCUsageStats/CCUsageStats/Auth/SettingsWindow.swift:110` — `SettingsViewModel.saveAndTest` switches over the same enum with no `default`. At line 118, group the new case with the inconclusive-verification branch:

```swift
        case .rateLimited, .transient, .insufficientScope:
```

A scope failure during token verification is a "couldn't verify" outcome, and `saveAndTest` is only ever handed the header client, which never returns `.insufficientScope`.

- [ ] **Step 5: Write the parser**

Create `CCUsageStats/CCUsageStats/Poller/OAuthUsage.swift`:

```swift
import Foundation

/// Parser for `GET https://api.anthropic.com/api/oauth/usage`.
///
/// Two things differ from the response-header path and are easy to get
/// wrong, so they are handled here at the boundary and nowhere else:
///   - `utilization` is already a percentage (0-100). The headers report a
///     0..1 fraction. `WindowSnapshot.usedPercentage` is percent, so this
///     value passes through unscaled.
///   - `resets_at` is an ISO 8601 string. The headers report epoch seconds.
enum OAuthUsage {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func epochSeconds(fromISO8601 s: String) -> Int64? {
        if let d = isoFractional.date(from: s) { return Int64(d.timeIntervalSince1970) }
        if let d = isoPlain.date(from: s) { return Int64(d.timeIntervalSince1970) }
        return nil
    }

    static func parse(status: Int, body: Data) -> AnthropicAPI.Result {
        switch status {
        case 200:
            if let snap = parseBody(body) { return .success(snap) }
            return .notSubscriber
        case 401:
            return .invalidToken
        case 403:
            let text = String(data: body, encoding: .utf8) ?? ""
            return text.contains("user:profile") ? .insufficientScope : .invalidToken
        case 429:
            return .rateLimited
        case 500...599:
            return .transient("server \(status)")
        default:
            return .transient("status \(status)")
        }
    }

    /// Returns nil when the body carries no recognizable window — an empty
    /// object, or the in-band error envelope the endpoint sometimes returns
    /// with a 200.
    static func parseBody(_ data: Data) -> RateLimitsSnapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        func window(_ key: String) -> WindowSnapshot? {
            guard let o = obj[key] as? [String: Any],
                  let util = o["utilization"] as? Double,
                  let iso = o["resets_at"] as? String,
                  let reset = epochSeconds(fromISO8601: iso) else {
                return nil
            }
            return WindowSnapshot(usedPercentage: util, resetsAt: reset)
        }

        var models: [String: WindowSnapshot] = [:]
        for key in obj.keys where UsageWindows.isModelKey(key) {
            if let w = window(key) { models[key] = w }
        }

        let five = window("five_hour")
        let seven = window("seven_day")
        if five == nil, seven == nil, models.isEmpty { return nil }
        return RateLimitsSnapshot(fiveHour: five, sevenDay: seven, models: models)
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `scripts/test.sh CCUsageStatsTests`

Expected: PASS — 12 new tests, and `AnthropicAPITests` still green.

- [ ] **Step 7: Commit**

```bash
git add CCUsageStats/CCUsageStats/Poller/OAuthUsage.swift CCUsageStats/CCUsageStats/Poller/AnthropicAPI.swift CCUsageStats/CCUsageStats/Poller/UsagePoller.swift CCUsageStats/CCUsageStats/Auth/SettingsWindow.swift CCUsageStats/CCUsageStatsTests/OAuthUsageTests.swift
git commit -m "feat: parse /api/oauth/usage windows

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: PKCE derivation

**Files:**
- Create: `CCUsageStats/CCUsageStats/Auth/PKCE.swift`
- Test: `CCUsageStats/CCUsageStatsTests/PKCETests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `PKCE.makeVerifier(byteCount:) -> String`, `PKCE.challenge(for:) -> String`, `PKCE.randomState() -> String`. Task 6 uses all three.

- [ ] **Step 1: Write the failing test**

Create `CCUsageStats/CCUsageStatsTests/PKCETests.swift`:

```swift
import XCTest
@testable import CCUsageStats

final class PKCETests: XCTestCase {
    /// RFC 7636 Appendix B test vector.
    func testChallengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(PKCE.challenge(for: verifier),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifierIsBase64URLAndWithinRFCLengthBounds() {
        let v = PKCE.makeVerifier()
        XCTAssertGreaterThanOrEqual(v.count, 43)
        XCTAssertLessThanOrEqual(v.count, 128)
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertNil(v.rangeOfCharacter(from: allowed.inverted),
                     "verifier must contain only unreserved characters")
    }

    func testVerifiersAreDistinct() {
        XCTAssertNotEqual(PKCE.makeVerifier(), PKCE.makeVerifier())
    }

    func testStateIsNonEmptyAndDistinct() {
        let a = PKCE.randomState()
        XCTAssertFalse(a.isEmpty)
        XCTAssertNotEqual(a, PKCE.randomState())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh CCUsageStatsTests/PKCETests`

Expected: FAIL — "cannot find 'PKCE' in scope".

- [ ] **Step 3: Write the implementation**

Create `CCUsageStats/CCUsageStats/Auth/PKCE.swift`:

```swift
import CryptoKit
import Foundation

/// RFC 7636 PKCE, S256 method.
enum PKCE {
    /// 32 random bytes base64url-encodes to 43 characters, the RFC minimum.
    static func makeVerifier(byteCount: Int = 32) -> String {
        base64URL(randomData(byteCount))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomState() -> String {
        base64URL(randomData(16))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomData(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh CCUsageStatsTests/PKCETests`

Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add CCUsageStats/CCUsageStats/Auth/PKCE.swift CCUsageStats/CCUsageStatsTests/PKCETests.swift
git commit -m "feat: add PKCE S256 derivation

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: OAuth session storage and renewal

**Files:**
- Create: `CCUsageStats/CCUsageStats/Auth/OAuthSession.swift`
- Test: `CCUsageStats/CCUsageStatsTests/OAuthSessionTests.swift`

**Interfaces:**
- Consumes: `TokenStore.serviceName` from `Auth/TokenStore.swift`.
- Produces: `struct OAuthSession` with fields `accessToken: String`, `refreshToken: String`, `expiresAt: Int64`, `scopes: [String]`; computed `hasProfileScope: Bool`; method `isExpiring(now:leeway:) -> Bool`. Plus `enum OAuthSessionStore { static func read() -> OAuthSession?; static func write(_:) throws; static func delete() throws }`. Tasks 6 and 8 use both.

- [ ] **Step 1: Write the failing test**

Create `CCUsageStats/CCUsageStatsTests/OAuthSessionTests.swift`:

```swift
import XCTest
@testable import CCUsageStats

final class OAuthSessionTests: XCTestCase {
    private let sample = OAuthSession(
        accessToken: "at",
        refreshToken: "rt",
        expiresAt: 1_000_000,
        scopes: ["user:profile"]
    )

    func testHasProfileScope() {
        XCTAssertTrue(sample.hasProfileScope)
        let without = OAuthSession(accessToken: "a", refreshToken: "r",
                                   expiresAt: 0, scopes: ["user:inference"])
        XCTAssertFalse(without.hasProfileScope)
    }

    func testIsExpiringUsesLeeway() {
        // 400s left, 300s leeway → not yet expiring.
        XCTAssertFalse(sample.isExpiring(now: 999_600, leeway: 300))
        // 200s left → expiring.
        XCTAssertTrue(sample.isExpiring(now: 999_800, leeway: 300))
        // Already past.
        XCTAssertTrue(sample.isExpiring(now: 1_000_001, leeway: 300))
    }

    func testJSONRoundTrip() throws {
        let data = try JSONEncoder().encode(sample)
        let back = try JSONDecoder().decode(OAuthSession.self, from: data)
        XCTAssertEqual(back, sample)
    }

    func testTokenResponseDecoding() throws {
        let json = """
        {"access_token":"at","refresh_token":"rt","expires_in":3600,
         "scope":"user:profile","token_type":"Bearer"}
        """
        let session = try XCTUnwrap(
            OAuthSession.fromTokenResponse(Data(json.utf8), now: 1_000)
        )
        XCTAssertEqual(session.accessToken, "at")
        XCTAssertEqual(session.refreshToken, "rt")
        XCTAssertEqual(session.expiresAt, 4_600)
        XCTAssertEqual(session.scopes, ["user:profile"])
    }

    func testTokenResponseAcceptsScopeArray() throws {
        let json = """
        {"access_token":"at","refresh_token":"rt","expires_in":60,
         "scope":["user:profile","user:inference"]}
        """
        let session = try XCTUnwrap(
            OAuthSession.fromTokenResponse(Data(json.utf8), now: 0)
        )
        XCTAssertEqual(session.scopes, ["user:profile", "user:inference"])
    }

    func testTokenResponseMissingAccessTokenReturnsNil() {
        let json = #"{"refresh_token":"rt","expires_in":60}"#
        XCTAssertNil(OAuthSession.fromTokenResponse(Data(json.utf8), now: 0))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh CCUsageStatsTests/OAuthSessionTests`

Expected: FAIL — "cannot find 'OAuthSession' in scope".

- [ ] **Step 3: Write the implementation**

Create `CCUsageStats/CCUsageStats/Auth/OAuthSession.swift`:

```swift
import Foundation
import Security

/// A scoped OAuth session for `GET /api/oauth/usage`.
///
/// Stored separately from the legacy pasted token (`TokenStore`, account
/// `oauth-token`), which is deliberately left intact so the response-header
/// fallback keeps working for users who never authorize.
struct OAuthSession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    /// Absolute expiry, epoch seconds.
    let expiresAt: Int64
    let scopes: [String]

    var hasProfileScope: Bool { scopes.contains("user:profile") }

    func isExpiring(now: Int64, leeway: Int64 = 300) -> Bool {
        expiresAt - now < leeway
    }

    /// Decodes an OAuth token-endpoint response. Returns nil when the body
    /// is not a successful token grant.
    static func fromTokenResponse(_ data: Data, now: Int64) -> OAuthSession? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String else {
            return nil
        }
        let expiresIn = (obj["expires_in"] as? Double) ?? 3600
        let scopes: [String]
        if let s = obj["scope"] as? String {
            scopes = s.split(separator: " ").map(String.init)
        } else if let a = obj["scope"] as? [String] {
            scopes = a
        } else {
            scopes = []
        }
        return OAuthSession(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: now + Int64(expiresIn),
            scopes: scopes
        )
    }
}

enum OAuthSessionStore {
    static let account = "oauth-session"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: TokenStore.serviceName,
            kSecAttrAccount as String: account,
        ]
    }

    static func read() -> OAuthSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthSession.self, from: data)
    }

    static func write(_ session: OAuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw TokenStore.TokenStoreError.unexpectedStatus(updateStatus)
        }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TokenStore.TokenStoreError.unexpectedStatus(addStatus)
        }
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else {
            throw TokenStore.TokenStoreError.unexpectedStatus(status)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh CCUsageStatsTests/OAuthSessionTests`

Expected: PASS — 6 tests. (These exercise the value type and response decoding only; `OAuthSessionStore` touches the real Keychain and is covered by the manual checklist in Task 9, not by unit tests.)

- [ ] **Step 5: Commit**

```bash
git add CCUsageStats/CCUsageStats/Auth/OAuthSession.swift CCUsageStats/CCUsageStatsTests/OAuthSessionTests.swift
git commit -m "feat: add scoped OAuth session type and keychain store

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: OAuth flow and dual-path poller

**Files:**
- Create: `CCUsageStats/CCUsageStats/Auth/OAuthFlow.swift`
- Create: `CCUsageStats/CCUsageStats/Poller/OAuthUsageClient.swift`
- Modify: `CCUsageStats/CCUsageStats/Poller/UsagePoller.swift`
- Modify: `CCUsageStats/CCUsageStats/Tray/MenuViewModel.swift`
- Test: `CCUsageStats/CCUsageStatsTests/UsagePollerTests.swift`

**Interfaces:**
- Consumes: `PKCE` (Task 4), `OAuthSession` / `OAuthSessionStore` (Task 5), `OAuthUsage.parse` (Task 3).
- Produces: `OAuthFlow.authorizeURL(challenge:state:redirectURI:) -> URL`, `OAuthFlow.exchange(code:verifier:state:redirectURI:) async throws -> OAuthSession`, `OAuthFlow.refresh(_:) async throws -> OAuthSession`, `OAuthUsageClient` conforming to `AnthropicAPIClient`, and `UsagePoller.init(api:fallback:cacheURL:clock:)` plus `@Published private(set) var needsReauthorization: Bool`. Task 8 reads `needsReauthorization`.

- [ ] **Step 1: Write the failing test**

Append to `CCUsageStats/CCUsageStatsTests/UsagePollerTests.swift`, inside the existing `final class UsagePollerTests: XCTestCase`. The class is already annotated `@MainActor` (line 4) and already nests a `StubAPI` client (lines 6–13) with a `queue` of results and a `calls` counter — reuse it rather than adding a second stub, and do not re-annotate the new methods.

```swift
func testInsufficientScopeFallsBackToSecondaryClient() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cc-usage-fallback-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let primary = StubAPI()
    primary.queue = [.insufficientScope]
    let fallback = StubAPI()
    fallback.queue = [.success(RateLimitsSnapshot(
        fiveHour: WindowSnapshot(usedPercentage: 33, resetsAt: 999),
        sevenDay: nil
    ))]

    let poller = UsagePoller(api: primary, fallback: fallback, cacheURL: url, clock: { 1 })
    await poller.tickForTest()

    XCTAssertEqual(fallback.calls, 1, "fallback must run on the same tick")
    XCTAssertTrue(poller.needsReauthorization)
    XCTAssertEqual(poller.authState, .ok, "fallback data is still good data")

    let cached = try XCTUnwrap(CacheStore.read(at: url))
    XCTAssertEqual(cached.snapshot.fiveHour?.usedPercentage, 33)
}

func testSuccessfulOAuthPathClearsReauthorizationFlag() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cc-usage-noreauth-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let primary = StubAPI()
    primary.queue = [
        .insufficientScope,
        .success(RateLimitsSnapshot(fiveHour: WindowSnapshot(usedPercentage: 1, resetsAt: 2),
                                    sevenDay: nil)),
    ]
    let fallback = StubAPI()
    fallback.queue = [
        .success(RateLimitsSnapshot(fiveHour: WindowSnapshot(usedPercentage: 33, resetsAt: 999),
                                    sevenDay: nil)),
    ]

    let poller = UsagePoller(api: primary, fallback: fallback, cacheURL: url, clock: { 1 })
    await poller.tickForTest()
    XCTAssertTrue(poller.needsReauthorization)

    await poller.tickForTest()
    XCTAssertFalse(poller.needsReauthorization, "a scoped success must clear the flag")
}

func testInsufficientScopeWithoutFallbackDoesNotStopPolling() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cc-usage-nofallback-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let primary = StubAPI()
    primary.queue = [.insufficientScope]
    let poller = UsagePoller(api: primary, fallback: nil, cacheURL: url, clock: { 1 })
    await poller.tickForTest()

    XCTAssertTrue(poller.needsReauthorization)
    XCTAssertNotEqual(poller.authState, .invalidToken)
    XCTAssertTrue(poller.isPolling, "the name of this test is the assertion")
}

func testOAuth401FallsBackInsteadOfStoppingWhenFallbackExists() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cc-usage-401-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let primary = StubAPI()
    primary.queue = [.invalidToken]
    let fallback = StubAPI()
    fallback.queue = [.success(RateLimitsSnapshot(
        fiveHour: WindowSnapshot(usedPercentage: 12, resetsAt: 999), sevenDay: nil
    ))]

    let poller = UsagePoller(api: primary, fallback: fallback, cacheURL: url, clock: { 1 })
    await poller.tickForTest()

    XCTAssertEqual(fallback.calls, 1)
    XCTAssertEqual(poller.authState, .ok,
                   "a dead OAuth session must not kill a working pasted token")
    XCTAssertTrue(poller.isPolling)
}

func testInvalidTokenWithoutFallbackStillStopsPolling() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cc-usage-dead-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let primary = StubAPI()
    primary.queue = [.invalidToken]
    let poller = UsagePoller(api: primary, fallback: nil, cacheURL: url, clock: { 1 })
    await poller.tickForTest()

    XCTAssertEqual(poller.authState, .invalidToken)
    XCTAssertFalse(poller.isPolling, "existing terminal-stop behavior must be preserved")
}

func testAuthorizeURLCarriesPKCEAndMinimalScope() throws {
    let url = OAuthFlow.authorizeURL(
        challenge: "CHAL",
        state: "STATE",
        redirectURI: "http://localhost:9999/callback"
    )
    let items = try XCTUnwrap(
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    )
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

    XCTAssertEqual(url.host, "claude.com")
    XCTAssertEqual(url.path, "/cai/oauth/authorize")
    XCTAssertEqual(value("client_id"), "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
    XCTAssertEqual(value("response_type"), "code")
    XCTAssertEqual(value("code_challenge"), "CHAL")
    XCTAssertEqual(value("code_challenge_method"), "S256")
    XCTAssertEqual(value("state"), "STATE")
    XCTAssertEqual(value("scope"), "user:profile")
    XCTAssertEqual(value("redirect_uri"), "http://localhost:9999/callback")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh CCUsageStatsTests/UsagePollerTests`

Expected: FAIL — "extra argument 'fallback' in call" and "cannot find 'OAuthFlow' in scope".

- [ ] **Step 3: Write the OAuth flow**

Create `CCUsageStats/CCUsageStats/Auth/OAuthFlow.swift`:

```swift
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
```

- [ ] **Step 4: Write the usage client**

Create `CCUsageStats/CCUsageStats/Poller/OAuthUsageClient.swift`:

```swift
import Foundation

/// Reads every rate-limit window from `GET /api/oauth/usage`.
///
/// Unlike the header path this is a plain GET: it costs no quota, and it is
/// the only source that exposes per-model weekly windows.
struct OAuthUsageClient: AnthropicAPIClient {
    let provider: OAuthTokenProvider
    let session: URLSession

    init(provider: OAuthTokenProvider, session: URLSession = .shared) {
        self.provider = provider
        self.session = session
    }

    func fetchRateLimits() async -> AnthropicAPI.Result {
        let token: String
        switch await provider.accessToken() {
        case .token(let t):
            token = t
        case .unusable:
            // No session, or the grant is permanently gone. The caller
            // treats this as "fall back to headers and ask for a reconnect".
            return .insufficientScope
        case .temporarilyUnavailable(let why):
            // Offline or a 5xx on refresh. Must stay transient so the
            // offline detector still counts it and the UI does not tell the
            // user to reauthorize over a dropped Wi-Fi connection.
            return .transient("token refresh: \(why)")
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return .transient("no http response")
            }
            return OAuthUsage.parse(status: http.statusCode, body: data)
        } catch {
            return .transient(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 5: Wire the fallback into the poller**

In `CCUsageStats/CCUsageStats/Poller/UsagePoller.swift`:

Add the stored property and published flag next to the existing ones:

```swift
    private let fallback: AnthropicAPIClient?

    /// True when the primary (OAuth) client was refused for scope reasons
    /// and data is coming from the header fallback. Drives the "reconnect"
    /// row in the dropdown.
    @Published private(set) var needsReauthorization = false
```

Replace the initializer:

```swift
    init(
        api: AnthropicAPIClient,
        fallback: AnthropicAPIClient? = nil,
        cacheURL: URL,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.api = api
        self.fallback = fallback
        self.cacheURL = cacheURL
        self.clock = clock
    }
```

Restructure `tick()` so the result handling is reusable:

```swift
    private func tick() async {
        let result = await api.fetchRateLimits()

        // Two ways the primary can be refused without the app being broken:
        // the token lacks user:profile, or the OAuth grant is dead. In both
        // cases a pasted fallback token may still work, so try it before
        // declaring the app unusable. Only a refusal with no fallback left
        // is terminal.
        let refused: Bool
        switch result {
        case .insufficientScope:
            refused = true
            needsReauthorization = true
            Self.log.warning("scoped usage endpoint refused; using header fallback")
        case .invalidToken where fallback != nil:
            refused = true
            needsReauthorization = true
            Self.log.warning("oauth session rejected; using header fallback")
        default:
            refused = false
        }

        if refused {
            if let fallback {
                handle(await fallback.fetchRateLimits())
            } else {
                // Keep polling and keep the flag set; the scope may come
                // back if the user authorizes in another window.
                transientFailureCount = 0
                currentBackoffSeconds = Self.baseInterval
            }
            return
        }

        if case .success = result { needsReauthorization = false }
        handle(result)
    }

    private func handle(_ result: AnthropicAPI.Result) {
        switch result {
        case .success(let snapshot):
            try? CacheStore.update(at: cacheURL, with: snapshot, now: clock())
            authState = .ok
            transientFailureCount = 0
            currentBackoffSeconds = Self.nextDelayAfterSuccess(snapshot: snapshot, now: clock())

        case .invalidToken:
            authState = .invalidToken
            stop()

        case .insufficientScope:
            // Only reachable when the fallback itself reports it, which the
            // header client never does. Treat as non-fatal.
            needsReauthorization = true

        case .notSubscriber:
            // Surface the state but keep polling. A missing rate-limit
            // header on a single response can be transient (brief Anthropic
            // hiccup, etc.). When headers return on a later poll the
            // .success branch flips authState back to .ok automatically.
            authState = .notSubscriber
            transientFailureCount = 0
            currentBackoffSeconds = Self.baseInterval

        case .rateLimited:
            currentBackoffSeconds = min(Self.maxBackoff, currentBackoffSeconds * 2)

        case .transient(let msg):
            Self.log.warning("transient: \(msg, privacy: .public)")
            transientFailureCount += 1
            if transientFailureCount >= Self.offlineThreshold {
                authState = .offline
            }
        }
    }
```

Remove the placeholder `.insufficientScope` case added in Task 3 Step 4 — it is replaced by the `handle(_:)` version above.

- [ ] **Step 6: Teach the view model's `attachPoller` the dual path**

`MenuViewModel` already funnels both `start()` and `restartPolling()` through one `attachPoller(token:)` (MenuViewModel.swift:268). Extend that method rather than adding a parallel construction path — the comment at :265-267 records that two copies of this wiring is exactly what dropped the status subscription once already.

Add a published mirror next to `authState`:

```swift
    @Published private(set) var needsReauthorization = false
```

`attachPoller` now needs two subscriptions instead of one, so widen the single cancellable at MenuViewModel.swift:76:

```swift
    /// The usage poller's subscriptions, held separately from `cancellables`
    /// because they are torn down and rebuilt every time the token changes.
    private var pollerCancellables: Set<AnyCancellable> = []
```

Replace every `pollerCancellable = nil` (in `stop()` at :169 and `restartPolling()` at :257) with `pollerCancellables.removeAll()`.

Replace `attachPoller` with:

```swift
    /// Builds a poller for whichever auth material is available, mirrors its
    /// published state, and starts it.
    ///
    /// Preference order:
    ///   1. Scoped OAuth session → /api/oauth/usage (every window, and a GET,
    ///      so it costs no quota), with the pasted token as fallback.
    ///   2. Pasted token only → response-header path (5h + 7d only).
    ///   3. Neither → nothing to poll with.
    private func attachPoller(token: String?) {
        let session = OAuthSessionStore.read()

        // True when no scoped session is stored — the common case on the
        // update that ships this, and the one the reconnect row exists for.
        // Held separately because the poller's own flag can only report a
        // *runtime* refusal, which the header-only configuration never
        // produces.
        let lacksScopedSession = !(session?.hasProfileScope ?? false)

        let primary: AnthropicAPIClient
        let fallback: AnthropicAPIClient?

        if let session, session.hasProfileScope {
            primary = OAuthUsageClient(provider: OAuthTokenProvider(session: session))
            fallback = token.map(apiFactory)
        } else if let token {
            primary = apiFactory(token)
            fallback = nil
        } else {
            authState = .noToken
            needsReauthorization = true
            return
        }

        let p = UsagePoller(api: primary, fallback: fallback, cacheURL: Paths.stateFile)
        p.$authState
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.applyAuthState($0)
                self?.reloadCache()
            }
            .store(in: &pollerCancellables)
        // OR with the static fact. A bare mirror would clobber it: @Published
        // republishes its current value (false) the moment we subscribe.
        p.$needsReauthorization
            .receive(on: RunLoop.main)
            .sink { [weak self] flag in
                self?.needsReauthorization = flag || lacksScopedSession
            }
            .store(in: &pollerCancellables)
        poller = p
        p.start()
    }
```

Both call sites must now pass through even without a pasted token, because a scoped session alone is enough to poll. In `start()` (:123-127) replace the `if let token { … } else { authState = .noToken }` block with:

```swift
        attachPoller(token: token)
```

In `restartPolling()` (:261-262) replace the `guard let token = loadStoredToken() else { … }` line and the call under it with:

```swift
        attachPoller(token: loadStoredToken())
```

Note `apiFactory` is used for both the fallback and the header-only primary, so the injected stub in `MenuViewModelTests` keeps working.

The `lacksScopedSession` OR is the point of this step. Without it the reconnect row never appears for a user who has only ever pasted a token — which is every existing user on the update that ships this.

- [ ] **Step 6b: Test the reconnect flag at the view-model level**

This is now testable: `MenuViewModelTests` injects `apiFactory` and `start()` no-ops under test. Append to `CCUsageStats/CCUsageStatsTests/MenuViewModelTests.swift`:

```swift
    func testReconnectFlagSetWhenOnlyAPastedTokenExists() throws {
        try TokenStore.write("sk-ant-oat01-stub")
        let vm = viewModel(polling: .success(
            RateLimitsSnapshot(fiveHour: WindowSnapshot(usedPercentage: 1, resetsAt: 2),
                               sevenDay: nil)
        ))
        vm.restartPollingForTest()
        XCTAssertTrue(vm.needsReauthorization,
                      "a header-only user must be told the model meter needs connecting")
    }

    func testReconnectFlagSetWhenNothingIsStored() {
        let vm = viewModel()
        vm.restartPollingForTest()
        XCTAssertEqual(vm.authState, .noToken)
        XCTAssertTrue(vm.needsReauthorization)
    }
```

`restartPolling()` is `private`. Add a test hook next to it in `MenuViewModel`, mirroring how `applyAuthState` was already split out for the same reason:

```swift
    /// Test seam: `start()` no-ops under test, so the state machine is driven
    /// through here instead.
    func restartPollingForTest() { restartPolling() }
```

In `start()`, replace the token-discovery block with `buildPoller()`. In `restartPolling()`, replace everything after `cancellables.removeAll()` with `needsReauthorization = false` followed by `buildPoller()`.

- [ ] **Step 7: Run tests to verify they pass**

Run: `scripts/test.sh CCUsageStatsTests`

Expected: PASS — the six new tests plus every existing test. Existing `UsagePoller(api:cacheURL:)` call sites still compile because `fallback` defaults to `nil`.

- [ ] **Step 8: Verify the app still builds**

Run: `scripts/build.sh`

Expected: `Built: dist/CCUsageStats.app (v… build …)` with no warnings introduced.

- [ ] **Step 9: Commit**

```bash
git add CCUsageStats/CCUsageStats/Auth/OAuthFlow.swift CCUsageStats/CCUsageStats/Poller/OAuthUsageClient.swift CCUsageStats/CCUsageStats/Poller/UsagePoller.swift CCUsageStats/CCUsageStats/Tray/MenuViewModel.swift CCUsageStats/CCUsageStatsTests/UsagePollerTests.swift
git commit -m "feat: dual-path poller with scoped OAuth usage endpoint

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Three-way split pill

**Files:**
- Create: `CCUsageStats/CCUsageStats/Tray/PillLayout.swift`
- Create: `CCUsageStats/CCUsageStats/Tray/MenuBarPillRenderer.swift`
- Modify: `CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift`
- Test: `CCUsageStats/CCUsageStatsTests/PillLayoutTests.swift`

**Interfaces:**
- Consumes: `WindowSnapshot` (Task 1), `UsageWindows.orderedModelKeys` (Task 2), `AuthState`.
- Produces: `PillSegment` with `kind: PillSegment.Kind` (`.fiveHour` / `.sevenDay` / `.model(String)`), `fraction: Double`, `text: String`; and `PillLayout.segments(five:seven:models:fiveText:authState:) -> [PillSegment]`.

- [ ] **Step 1: Write the failing test**

Create `CCUsageStats/CCUsageStatsTests/PillLayoutTests.swift`:

```swift
import XCTest
@testable import CCUsageStats

final class PillLayoutTests: XCTestCase {
    private func w(_ pct: Double) -> WindowSnapshot {
        WindowSnapshot(usedPercentage: pct, resetsAt: 1_000)
    }

    private func segments(
        five: Double?, seven: Double?, models: [String: Double],
        authState: AuthState = .ok, now: Int64 = 0
    ) -> [PillSegment] {
        PillLayout.segments(
            five: five.map(w),
            seven: seven.map(w),
            models: models.mapValues(w),
            fiveText: five.map { "\(Int($0))%" } ?? "—",
            authState: authState,
            now: now
        )
    }

    func testQuietStateIsFiveHourOnly() {
        let s = segments(five: 42, seven: 30, models: ["seven_day_fable": 12])
        XCTAssertEqual(s.map(\.kind), [.fiveHour])
    }

    func testSevenDayJoinsAboveThresholdAndAboveFiveHour() {
        let s = segments(five: 42, seven: 88, models: [:])
        XCTAssertEqual(s.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(s[1].text, "88%")
    }

    func testSevenDayDoesNotJoinWhenBelowFiveHour() {
        // 7d is above 80% but 5h is higher — 5h is the dominant concern.
        let s = segments(five: 95, seven: 85, models: [:])
        XCTAssertEqual(s.map(\.kind), [.fiveHour])
    }

    func testModelJoinsIndependentlyOfSevenDay() {
        let s = segments(five: 42, seven: 30, models: ["seven_day_fable": 93])
        XCTAssertEqual(s.map(\.kind), [.fiveHour, .model("seven_day_fable")])
    }

    func testThreeWaySplitWhenBothQualify() {
        let s = segments(five: 42, seven: 88, models: ["seven_day_fable": 93])
        XCTAssertEqual(s.map(\.kind), [.fiveHour, .sevenDay, .model("seven_day_fable")])
    }

    func testHighestModelWins() {
        let s = segments(five: 10, seven: 0,
                         models: ["seven_day_fable": 84, "seven_day_sonnet": 97])
        XCTAssertEqual(s.map(\.kind), [.fiveHour, .model("seven_day_sonnet")])
    }

    func testDenylistedKeysNeverPromote() {
        let s = segments(five: 10, seven: 0, models: ["seven_day_oauth_apps": 99])
        XCTAssertEqual(s.map(\.kind), [.fiveHour])
    }

    func testFiveHourAtCapStaysSingleSegment() {
        let s = segments(five: 100, seven: 88, models: ["seven_day_fable": 93])
        XCTAssertEqual(s.map(\.kind), [.fiveHour])
    }

    func testNoUsableTokenStaysSingleSegment() {
        for state in AuthState.allCases where state.lacksWorkingToken {
            let s = segments(five: 42, seven: 88, models: ["seven_day_fable": 93],
                             authState: state)
            XCTAssertEqual(s.map(\.kind), [.fiveHour], "state: \(state)")
        }
    }

    func testPollableStatesStillSplit() {
        for state in AuthState.allCases where !state.lacksWorkingToken {
            let s = segments(five: 42, seven: 88, models: [:], authState: state)
            XCTAssertEqual(s.map(\.kind), [.fiveHour, .sevenDay], "state: \(state)")
        }
    }

    func testMissingFiveHourYieldsNoSegments() {
        let s = segments(five: nil, seven: 88, models: [:])
        XCTAssertTrue(s.isEmpty)
    }

    func testFractionIsClampedButTextIsNot() {
        // Color must saturate at the top of the ramp; the text keeps
        // reporting what the server said, matching pre-existing behavior.
        let s = segments(five: 42, seven: 130, models: [:])
        XCTAssertEqual(s[1].fraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(s[1].text, "130%")
    }

    func testExpiredModelWindowDoesNotPromote() {
        // `w()` resets at t=1000. A model window whose reset has passed is
        // stale data the poller can no longer refresh — most likely a
        // leftover from before the user disconnected their account. It must
        // not keep claiming menubar space.
        let s = segments(five: 10, seven: 0, models: ["seven_day_fable": 93], now: 2_000)
        XCTAssertEqual(s.map(\.kind), [.fiveHour])
    }

    func testLiveModelWindowStillPromotesAtBoundary() {
        let s = segments(five: 10, seven: 0, models: ["seven_day_fable": 93], now: 999)
        XCTAssertEqual(s.map(\.kind), [.fiveHour, .model("seven_day_fable")])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh CCUsageStatsTests/PillLayoutTests`

Expected: FAIL — "cannot find 'PillLayout' in scope".

- [ ] **Step 3: Write the layout logic**

Create `CCUsageStats/CCUsageStats/Tray/PillLayout.swift`:

```swift
import Foundation

struct PillSegment: Equatable {
    enum Kind: Equatable {
        case fiveHour
        case sevenDay
        case model(String)
    }

    let kind: Kind
    /// 0..1, clamped.
    let fraction: Double
    let text: String
}

/// Decides which windows share the menubar pill.
///
/// Pure so the gating matrix is testable without AppKit. Reachable states:
/// `5h`, `5h│7d`, `5h│model`, `5h│7d│model`.
enum PillLayout {
    /// A window must be this far along before it earns menubar space.
    static let promoteThreshold = 0.8

    static func segments(
        five: WindowSnapshot?,
        seven: WindowSnapshot?,
        models: [String: WindowSnapshot],
        fiveText: String,
        authState: AuthState,
        now: Int64
    ) -> [PillSegment] {
        guard let five else { return [] }
        let fiveFraction = clamp(five.usedPercentage / 100.0)
        var result = [PillSegment(kind: .fiveHour, fraction: fiveFraction, text: fiveText)]

        // No usable token renders a bare triangle; at cap the 5h half shows a
        // countdown that is wide enough on its own. Neither shares the pill.
        // `lacksWorkingToken` covers both .noToken and .invalidToken — the
        // distinction matters for the copy shown, not for pill layout.
        guard !authState.lacksWorkingToken, fiveFraction < 1.0 else { return result }

        func qualifies(_ fraction: Double) -> Bool {
            fraction > promoteThreshold && fraction >= fiveFraction
        }

        if let seven {
            let f = clamp(seven.usedPercentage / 100.0)
            if qualifies(f) {
                result.append(.init(
                    kind: .sevenDay, fraction: f, text: percentText(seven.usedPercentage)
                ))
            }
        }

        // Independent of whether 7d qualified: the model window is a
        // separate limit and can be the only one in trouble.
        //
        // Expired windows are excluded. Model windows are merged per key and
        // never deleted from the cache, so a user who disconnects their
        // account leaves a frozen value behind — without this guard it would
        // claim menubar space forever with data nothing can refresh.
        let candidates = UsageWindows.orderedModelKeys(models)
            .compactMap { key -> (String, WindowSnapshot)? in
                guard let w = models[key], w.resetsAt > now else { return nil }
                return (key, w)
            }
        let top = candidates.max { $0.1.usedPercentage < $1.1.usedPercentage }
        if let top {
            let f = clamp(top.1.usedPercentage / 100.0)
            if qualifies(f) {
                result.append(.init(
                    kind: .model(top.0), fraction: f, text: percentText(top.1.usedPercentage)
                ))
            }
        }

        return result
    }

    private static func clamp(_ v: Double) -> Double { max(0.0, min(1.0, v)) }

    /// Text reports the raw server percentage; only the color fraction is
    /// clamped. Matches the pre-existing 7d rendering.
    private static func percentText(_ percentage: Double) -> String {
        "\(Int(percentage.rounded()))%"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh CCUsageStatsTests/PillLayoutTests`

Expected: PASS — 14 tests.

- [ ] **Step 5: Extract the N-segment renderer**

Create `CCUsageStats/CCUsageStats/Tray/MenuBarPillRenderer.swift` with the pill drawing moved out of `MenuBarContent.swift`. This replaces `renderSplitPill` with a loop over segments; `renderSinglePill` moves across unchanged.

```swift
import AppKit

/// Draws the menubar label as a single NSImage with `isTemplate = false` —
/// the only reliable way to keep custom colors in the macOS menubar.
enum MenuBarPillRenderer {
    struct Style {
        let onColor: NSColor
        let staleAlpha: CGFloat
        let outageIcon: NSImage?
    }

    private static let outerPadX: CGFloat = 7
    private static let dividerPadX: CGFloat = 7
    private static let outerPadY: CGFloat = 2
    private static let iconTextGap: CGFloat = 6

    /// Multi-segment capsule, one color band per segment.
    ///
    /// The divider gets more contrast at three segments: adjacent
    /// high-utilization bands converge in the orange-red end of the OKLab
    /// ramp, and a faint hairline lets them read as one blob.
    static func renderSplitPill(segments: [PillSegment], style: Style) -> NSImage {
        precondition(segments.count >= 2, "use renderSinglePill for one segment")

        let dividerAlpha: CGFloat = segments.count >= 3 ? 0.7 : 0.45

        struct Piece {
            let icon: NSImage
            let attr: NSAttributedString
            let color: NSColor
            let width: CGFloat
        }

        let pieces: [Piece] = segments.map { seg in
            let icon = makeIcon(symbol: symbol(for: seg), color: style.onColor)
            let attr = makeAttr(seg.text, color: style.onColor)
            let color = UsageColor.nsColor(t: seg.fraction)
                .withAlphaComponent(style.staleAlpha)
            return Piece(
                icon: icon, attr: attr, color: color,
                width: icon.size.width + iconTextGap + attr.size().width
            )
        }

        // Outer edges get outerPadX; every internal boundary gets
        // dividerPadX on each side.
        var bandWidths: [CGFloat] = []
        for (i, p) in pieces.enumerated() {
            let leading = (i == 0) ? outerPadX : dividerPadX
            let trailing = (i == pieces.count - 1) ? outerPadX : dividerPadX
            bandWidths.append(leading + p.width + trailing)
        }

        let pillW = bandWidths.reduce(0, +)
        let innerH = pieces.map { max($0.icon.size.height, $0.attr.size().height) }.max() ?? 0
        let pillH = innerH + 2 * outerPadY
        let radius = pillH / 2

        let outageGap: CGFloat = style.outageIcon != nil ? 6 : 0
        let outageW = style.outageIcon?.size.width ?? 0
        let totalW = pillW + outageGap + outageW
        let totalH = max(pillH, style.outageIcon?.size.height ?? 0)

        let composite = NSImage(size: NSSize(width: totalW, height: totalH), flipped: false) { _ in
            let pillRect = NSRect(x: 0, y: (totalH - pillH) / 2, width: pillW, height: pillH)
            let path = NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius)

            NSGraphicsContext.current?.saveGraphicsState()
            path.addClip()
            var x = pillRect.minX
            for (i, p) in pieces.enumerated() {
                p.color.setFill()
                NSRect(x: x, y: pillRect.minY, width: bandWidths[i], height: pillH).fill()
                x += bandWidths[i]
            }
            NSGraphicsContext.current?.restoreGraphicsState()

            // Dividers at every internal boundary.
            var boundary = pillRect.minX
            for i in 0..<(pieces.count - 1) {
                boundary += bandWidths[i]
                let divider = NSBezierPath()
                divider.move(to: NSPoint(x: boundary, y: pillRect.minY + 3))
                divider.line(to: NSPoint(x: boundary, y: pillRect.maxY - 3))
                divider.lineWidth = 1
                style.onColor
                    .withAlphaComponent(style.staleAlpha * dividerAlpha)
                    .setStroke()
                divider.stroke()
            }

            // Content.
            var contentX = pillRect.minX
            for (i, p) in pieces.enumerated() {
                let leading = (i == 0) ? outerPadX : dividerPadX
                p.icon.draw(in: NSRect(
                    x: contentX + leading,
                    y: (totalH - p.icon.size.height) / 2,
                    width: p.icon.size.width, height: p.icon.size.height
                ))
                p.attr.draw(at: NSPoint(
                    x: contentX + leading + p.icon.size.width + iconTextGap,
                    y: (totalH - p.attr.size().height) / 2
                ))
                contentX += bandWidths[i]
            }

            if let oi = style.outageIcon {
                oi.draw(in: NSRect(
                    x: pillW + outageGap, y: (totalH - oi.size.height) / 2,
                    width: oi.size.width, height: oi.size.height
                ))
            }
            return true
        }
        composite.isTemplate = false
        return composite
    }

    static func symbol(for segment: PillSegment) -> String {
        switch segment.kind {
        case .fiveHour: return gauge(for: segment.fraction)
        case .sevenDay: return "calendar"
        case .model:    return "sparkles"
        }
    }

    /// Picks a gauge.with.dots.needle symbol matching the fraction band.
    static func gauge(for fraction: Double) -> String {
        switch fraction {
        case ..<0.125: return "gauge.with.dots.needle.0percent"
        case ..<0.375: return "gauge.with.dots.needle.33percent"
        case ..<0.625: return "gauge.with.dots.needle.50percent"
        case ..<0.875: return "gauge.with.dots.needle.67percent"
        default:       return "gauge.with.dots.needle.100percent"
        }
    }

    static func makeIcon(symbol: String, color: NSColor) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: nil)
        return img?.withSymbolConfiguration(cfg) ?? NSImage(size: NSSize(width: 14, height: 14))
    }

    static func makeAttr(_ s: String, color: NSColor) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .semibold)
        return NSAttributedString(string: s, attributes: [.foregroundColor: color, .font: font])
    }
}
```

- [ ] **Step 6: Point `MenuBarLabel` at the new renderer**

In `CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift`:

Replace **lines 35–54 inclusive** of `MenuBarContent.swift` — from `let five = vm.cached?.snapshot.fiveHour` down to and including the closing brace of the outer `if !vm.authState.lacksWorkingToken, let five, let seven, !fiveAtCap { … }`. The `if showSeven { … }` block is nested inside that outer `if`; stopping at the inner brace strands the outer one and will not compile.

```swift
        let segments = PillLayout.segments(
            five: vm.cached?.snapshot.fiveHour,
            seven: vm.cached?.snapshot.sevenDay,
            models: vm.cached?.snapshot.models ?? [:],
            fiveText: vm.displayState.menuBarText,
            authState: vm.authState,
            now: Int64(Date().timeIntervalSince1970)
        )
        if segments.count >= 2 {
            return MenuBarPillRenderer.renderSplitPill(
                segments: segments,
                style: .init(onColor: onColor, staleAlpha: staleAlpha, outageIcon: outageIcon)
            )
        }
```

Delete `renderSplitPill(...)`, `gauge(for:)`, `makeIcon(symbol:color:)`, and `makeAttr(_:color:)` from `MenuBarLabel` — they now live on `MenuBarPillRenderer`. In `renderSinglePill`, replace the two calls with `MenuBarPillRenderer.makeIcon(symbol:color:)` and `MenuBarPillRenderer.makeAttr(_:color:)`, and in `glyph()` replace the inline needle switch with `MenuBarPillRenderer.gauge(for: f)`.

- [ ] **Step 7: Run tests and build**

Run: `scripts/test.sh CCUsageStatsTests`

Expected: PASS — all tests, including the existing `DisplayStateTests` and `UsageColorTests`.

Run: `scripts/build.sh`

Expected: builds clean with no new warnings.

- [ ] **Step 8: Verify on-device rendering**

The pill is drawn, not asserted — unit tests cannot confirm it looks right. Launch the built app and confirm each reachable state renders:

```bash
open dist/CCUsageStats.app
```

Confirm by editing `~/Library/Application Support/cc-usage-stats/state.json` directly (the app watches the file and redraws within a second). For the three-way state, write:

```json
{"captured_at":1785200000,
 "five_hour":{"used_percentage":42,"resets_at":1785220000},
 "seven_day":{"used_percentage":88,"resets_at":1785700000},
 "model_windows":{"seven_day_fable":{"used_percentage":93,"resets_at":1785700000}}}
```

Check: three bands, two visible dividers, no clipped text, readable in both light and dark menubars (toggle System Settings → Appearance).

- [ ] **Step 9: Commit**

```bash
git add CCUsageStats/CCUsageStats/Tray/PillLayout.swift CCUsageStats/CCUsageStats/Tray/MenuBarPillRenderer.swift CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift CCUsageStats/CCUsageStatsTests/PillLayoutTests.swift
git commit -m "feat: three-way split pill for per-model weekly window

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Dropdown rows and connect button

**Files:**
- Modify: `CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift`
- Modify: `CCUsageStats/CCUsageStats/Tray/MenuViewModel.swift`
- Modify: `CCUsageStats/CCUsageStats/Auth/SettingsWindow.swift`

**Interfaces:**
- Consumes: `UsageWindows.orderedModelKeys` / `.label(for:)` (Task 2), `MenuViewModel.needsReauthorization` (Task 6), `OAuthFlow` / `OAuthSessionStore` (Tasks 5–6).
- Produces: `MenuViewModel.connectAccount()`.

- [ ] **Step 1: Add the model rows to the dropdown**

In `MenuBarDropdown.body`, directly after the existing `WindowSection(title: "7-day window", …)` at MenuBarContent.swift:375 and before the `Divider()` at :377:

```swift
                ForEach(UsageWindows.orderedModelKeys(cached.snapshot.models), id: \.self) { key in
                    WindowSection(
                        title: UsageWindows.label(for: key),
                        window: cached.snapshot.models[key],
                        now: now
                    )
                }
```

`WindowSection` already handles a nil window and omits the sparkline when `sparkline` is nil, so no change is needed there.

- [ ] **Step 2: Add the reconnect row**

In `MenuBarDropdown`, add a sibling of `authStatusRow` (:637) — a separate row, not a branch inside it, because this is independent of auth state: the fallback path reports `.ok` while still needing the prompt.

```swift
    @ViewBuilder
    private var reauthorizeRow: some View {
        // Suppressed when there is no working token at all — "connect for the
        // model meter" is noise next to "token rejected, set a token".
        if vm.needsReauthorization, !vm.authState.lacksWorkingToken {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Connect your account to see per-model weekly usage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
```

Render it in `body` between `authStatusRow` (:410) and `tokenExpiryRow` (:411):

```swift
            reauthorizeRow
```

- [ ] **Step 3: Add the connect action**

In `MenuViewModel`, add:

```swift
    /// Runs the browser OAuth flow and rebuilds the poller on success.
    func connectAccount() {
        Task { @MainActor in
            do {
                let session = try await OAuthFlow.runInteractive()
                try OAuthSessionStore.write(session)
                restartPolling()
            } catch {
                lastError = "Connect failed: \(error)"
            }
        }
    }
```

In `OAuthFlow`, add the interactive driver. It binds a loopback listener, opens the browser, and waits for the redirect. If the listener cannot bind it throws `FlowError.listenerFailed`, which `connectAccount()` surfaces via `lastError` — see the deviation note under Known Unknowns.

```swift
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
```

Add `LoopbackRedirectListener` to `OAuthFlow.swift`, below the enum. It serves one request, replies with a plain confirmation page, and yields the query parameters.

```swift
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
```

- [ ] **Step 4: Add the Settings button**

Hang the action off `SettingsViewModel` rather than adding a second closure to `SettingsView`. `SettingsWindowController.show(viewModel:)` (SettingsWindow.swift:16) already passes `onClose` as a trailing closure; threading another one through means changing that call site and the initializer, for no gain. This mirrors how `tryClaudeCodeKeychain()` is already reached.

In `SettingsViewModel`, next to `onSaveSuccess`:

```swift
    /// Set by the caller that owns the poller. Optional because the settings
    /// window is constructible without it in previews and tests.
    var onConnect: (() -> Void)?
```

In `SettingsView`, next to the existing `Button("Paste from Claude Code Keychain")` at line 145:

```swift
                Button("Connect Claude account") { vm.onConnect?() }
```

In `MenuViewModel.openSettings()` (:190-194), set it on the view model before showing:

```swift
    func openSettings() {
        let vm = SettingsViewModel { [weak self] _ in
            self?.restartPolling()
        }
        vm.onConnect = { [weak self] in self?.connectAccount() }
        SettingsWindowController.shared.show(viewModel: vm)
    }
```

- [ ] **Step 5: Build and verify**

Run: `scripts/test.sh CCUsageStatsTests`

Expected: PASS — no test changes, nothing regressed.

Run: `scripts/build.sh`

Expected: builds clean.

- [ ] **Step 6: Verify the flow end to end**

```bash
open dist/CCUsageStats.app
```

From the dropdown, open Settings and click "Connect Claude account". Confirm: the browser opens to `claude.com/cai/oauth/authorize`, approving returns to a local confirmation page, the dropdown reconnect row disappears within one poll interval, and a per-model row appears.

If the real response uses a key other than `seven_day_fable`, the row's label follows the wire — that is the designed behavior, not a bug. Record the actual key observed in the commit message.

- [ ] **Step 7: Commit**

```bash
git add CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift CCUsageStats/CCUsageStats/Tray/MenuViewModel.swift CCUsageStats/CCUsageStats/Auth/SettingsWindow.swift CCUsageStats/CCUsageStats/Auth/OAuthFlow.swift
git commit -m "feat: per-model dropdown rows and account connect flow

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/manual-test-checklist.md`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing consumed by code.

- [ ] **Step 1: Survey the docs**

Run: `grep -rn "anthropic-ratelimit-unified\|7-day\|five_hour" README.md docs/manual-test-checklist.md`

Read every hit. The "How it works" section at `README.md:137`, and specifically the header list at `:141`, documents the header-only data source and is now incomplete — it must describe both paths.

- [ ] **Step 2: Update `README.md`**

In the data-source section around line 103, replace the header-only description with both paths: the response-header path (5h + 7d, works with a pasted token, costs a 1-token request per poll) and the `GET /api/oauth/usage` path (adds per-model weekly windows, requires connecting an account for the `user:profile` scope, costs no quota). State that model-window labels are derived from the wire key, so the row name tracks whatever the API returns.

- [ ] **Step 3: Update `docs/manual-test-checklist.md`**

Add these cases:

```markdown
## Per-model weekly meter

- [ ] Fresh install with a pasted token only: 5h and 7d render; the dropdown
      shows the "Connect your account" row; no model row appears.
- [ ] After "Connect Claude account": browser opens, approval returns to the
      local confirmation page, the connect row disappears within one poll.
- [ ] A per-model row appears in the dropdown with a percentage and a reset
      caption. Note the exact key/label observed.
- [ ] Menubar quiet state (all windows below 80%) shows a single 5h pill.
- [ ] Model window above 80% with 7d below: pill shows 5h │ model.
- [ ] Both above 80%: pill shows 5h │ 7d │ model, two dividers visible,
      readable in both light and dark menubars.
- [ ] 5h at 100%: pill reverts to the single countdown pill regardless of the
      other windows.
- [ ] Kill network mid-poll: last values persist, no row disappears.
- [ ] Restart the app: the model row is still populated from cache.
- [ ] Go offline for longer than the access-token lifetime: the dropdown
      shows "Offline — last value shown", NOT the connect-your-account row.
      (A failed refresh must not be reported as a scope problem.)
- [ ] Disconnect the account, keep a pasted token: within one poll the
      per-model pill segment disappears once that window's reset passes,
      and the connect row returns.
```

- [ ] **Step 4: Commit**

```bash
git add README.md docs/manual-test-checklist.md
git commit -m "docs: document the per-model weekly meter and connect flow

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Verification Before Completion

Do not report this feature complete until all of the following have been run and their output inspected:

- [ ] `scripts/test.sh` — full unit bundle passes
- [ ] `scripts/build.sh` — Release build succeeds with no new warnings
- [ ] The on-device checks in Task 7 Step 8 and Task 8 Step 6 have actually been performed — the pill is drawn, not asserted, and the OAuth flow cannot be unit-tested
- [ ] `docs/manual-test-checklist.md` per-model section walked through against the running app

## Known Unknowns

- The exact model-window key this account receives (`seven_day_fable` vs `seven_day_opus`) is unverified — it could not be determined without a scoped token. The design enumerates keys rather than matching one, so either works; record what you observe in Task 8 Step 6.
- Claude Code sends additional authorize parameters (`code=true`, `login_hint`, `login_method`) that were not traced. They are omitted here. If the authorize page rejects the request, add `code=true` first.
- `OAuthSessionStore` is not unit-tested because it touches the real Keychain; it is covered by the manual checklist.

**Deviation from the spec:** the spec calls for a manual paste-the-code fallback when the loopback listener cannot bind. This plan drops it (YAGNI) — binding an ephemeral loopback port does not fail in practice, and the fallback would be a second, untested redirect path. `FlowError.listenerFailed` surfaces to the user instead. If it ever fires in the wild, add the manual path then.
