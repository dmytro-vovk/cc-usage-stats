# cc-usage-stats Phase 2 — OAuth Poller — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pivot the data source from Claude Code's statusline JSON to a self-driven poller of the official Anthropic `/v1/messages` API, so usage shows in the menubar regardless of how the user accesses Claude.

**Architecture:** Single-process tray app polls `POST /v1/messages` every 60s with an OAuth long-lived token (auto-discovered from the existing `Claude Code-credentials` Keychain entry where possible, paste fallback otherwise). Response's `rate_limits` block is parsed and written to the same `state.json` cache the Phase 1 UI already consumes. Phase 1 statusline integration is removed and the user's `~/.claude/settings.json` is restored on first launch.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit (`NSWorkspace`, `SecItem*` via `Security` framework), `URLSession`, XCTest.

**Spec:** [`docs/superpowers/specs/2026-04-25-cc-usage-stats-poller-design.md`](../specs/2026-04-25-cc-usage-stats-poller-design.md)

---

## File Structure

App sources (real paths under `CCUsageStats/CCUsageStats/`):

| File | Responsibility |
|------|----------------|
| `Auth/AuthState.swift` | `enum AuthState { unknown, ok, invalidToken, notSubscriber, offline }` |
| `Auth/TokenStore.swift` | Read / write our OAuth token via `SecItem*` (generic-password, `kSecAttrService = "cc-usage-stats"`, `kSecAttrAccount = "oauth-token"`). |
| `Auth/ClaudeCodeKeychainProbe.swift` | One-shot best-effort read of the existing `Claude Code-credentials` keychain entry. |
| `Auth/SettingsWindow.swift` | Floating SwiftUI window: paste field, "Paste from Claude Code Keychain", "Save & Test", "Cancel". |
| `Poller/AnthropicAPI.swift` | Request builder + response parser (body and header paths). |
| `Poller/UsagePoller.swift` | `@MainActor` state machine — timer, error transitions, backoff. |
| `Migration/Phase1Cleanup.swift` | One-shot Phase 1 migration on first v2.0 launch. |

Sources to delete:

| Path | Why |
|------|-----|
| `Statusline/StatuslineMode.swift` | No more statusline mode. |
| `Statusline/WrappedCommand.swift` | No more wrapped commands. |
| `Tray/Installer.swift` | Migration uses inline reverse logic; we no longer install. |
| `Tray/CacheWatcher.swift` | We own all writes; no FSEvents needed. |
| `Tests/StatuslineModeTests.swift` | Source removed. |
| `Tests/WrappedCommandTests.swift` | Source removed. |
| `Tests/InstallerTests.swift` | Source removed. |
| `Tests/CacheWatcherTests.swift` | Source removed. |
| `Tests/Fixtures/statusline-*.json` | No longer referenced. |

Sources to modify:

| File | Change |
|------|--------|
| `CCUsageStatsApp.swift` | Drop statusline-mode argv branch; on launch run `Phase1Cleanup`, then token discovery, then start poller. |
| `Tray/MenuViewModel.swift` | Replace install / launch-at-login / path-mismatch / cache-watcher state with poller + auth state. Keep launch-at-login. |
| `Tray/MenuBarContent.swift` | Drop install / uninstall / path-mismatch UI. Add "Set Token… / Reset Token…", token-error row, "Offline" tag, auth-error icon. |

Tests added:

| File | Covers |
|------|--------|
| `Tests/AuthStateTests.swift` | Trivial enum sanity (mostly to ensure the file is wired into the test target). |
| `Tests/TokenStoreTests.swift` | Round-trip Keychain entry; cleans up. |
| `Tests/AnthropicAPITests.swift` | Fixture-driven body parse, header parse, missing both, malformed JSON, model-fallback request shape. |
| `Tests/UsagePollerTests.swift` | State-machine transitions with a stub `AnthropicAPIClient` protocol injected. |
| `Tests/Phase1CleanupTests.swift` | Snapshot the migration of `~/.claude/settings.json` + presence of sentinel. |

---

## Conventions

- TDD: failing test → minimal implementation → green → commit. Same as Phase 1.
- Commit subject ≤72 chars, with `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` trailer.
- Atomic file writes for any disk artifact (use the same pattern Phase 1 established).
- macOS 13+ deployment target (unchanged).
- Keychain access: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Token never logged.
- Build/test commands: same as Phase 1 — `xcodebuild test -scheme CCUsageStats -destination 'platform=macOS' -project CCUsageStats/CCUsageStats.xcodeproj -only-testing:CCUsageStatsTests/<TestClass>`.

---

## Task 1: Verify the API protocol (BLOCKING for downstream parser)

This task **must** happen before Task 6 (`AnthropicAPI`). It empirically determines whether `rate_limits` arrives in the response body, in headers, or both — and what the field names actually are.

**No code, no commit.** Output is a paragraph in this plan or a TODO note in the eventual `AnthropicAPI.swift`.

- [ ] **Step 1.1: Get a long-lived OAuth token**

If not already done: `claude setup-token` in a terminal. Copy the resulting `sk-ant-oat01-…` value to a safe place. **Do not paste it into source files, do not commit it, do not log it in this conversation when running curl — use a shell variable.**

```bash
read -r TOKEN
# paste the sk-ant-oat01-... token, press enter
```

- [ ] **Step 1.2: Probe `/v1/messages`**

```bash
curl -isS https://api.anthropic.com/v1/messages \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"."}]}' \
  | tee /tmp/probe-no-beta.txt
```

If the response is 4xx with a message about beta access, retry with `-H "anthropic-beta: oauth-2025-04-20"` (the header observed for OAuth in past Anthropic docs); save to `/tmp/probe-with-beta.txt`.

- [ ] **Step 1.3: Inspect headers and body for rate-limit data**

```bash
echo "=== HEADERS ==="
sed -n '1,/^\r$/p' /tmp/probe-no-beta.txt | grep -i -E "anthropic|rate|limit"
echo "=== BODY (rate-related keys) ==="
sed -n '/^\r$/,$p' /tmp/probe-no-beta.txt | grep -o '"[a-z_]*\(rate\|limit\|usage\|five_hour\|seven_day\|reset\)[a-z_]*"' | sort -u
```

Repeat for `/tmp/probe-with-beta.txt` if it was produced.

- [ ] **Step 1.4: Record the result**

In a short note appended to this plan file (under a new "Protocol Verification Result" subsection in Task 1), write:

- Which header was needed (none, or `anthropic-beta: oauth-2025-04-20`).
- Whether `rate_limits` is in the JSON body, the response headers, or both.
- Exact field names (`used_percentage` vs `utilization`, `resets_at` epoch-int vs ISO-8601 string, etc.).
- Any unexpected response codes or required headers.

This locks the parser implementation in Task 6.

- [ ] **Step 1.5: Wipe the probe files**

```bash
shred -u /tmp/probe-no-beta.txt /tmp/probe-with-beta.txt 2>/dev/null || rm -f /tmp/probe-no-beta.txt /tmp/probe-with-beta.txt
```

(macOS `shred` doesn't ship by default; `rm` is acceptable on the local machine.)

---

## Task 2: AuthState enum

**Files:**
- Create: `CCUsageStats/CCUsageStats/Auth/AuthState.swift`
- Create: `CCUsageStats/CCUsageStatsTests/AuthStateTests.swift`

- [ ] **Step 2.1: Write the failing test**

```swift
import XCTest
@testable import CCUsageStats

final class AuthStateTests: XCTestCase {
    func testAllCasesExist() {
        let all: [AuthState] = [.unknown, .ok, .invalidToken, .notSubscriber, .offline]
        XCTAssertEqual(Set(all).count, 5)
    }
    func testEquatable() {
        XCTAssertEqual(AuthState.ok, AuthState.ok)
        XCTAssertNotEqual(AuthState.ok, AuthState.offline)
    }
}
```

- [ ] **Step 2.2: Run, expect FAIL.**

- [ ] **Step 2.3: Implementation**

```swift
import Foundation

enum AuthState: Equatable {
    case unknown
    case ok
    case invalidToken
    case notSubscriber
    case offline
}
```

- [ ] **Step 2.4: Run, expect PASS.**

- [ ] **Step 2.5: Commit**

```bash
git add CCUsageStats/CCUsageStats/Auth/AuthState.swift CCUsageStats/CCUsageStatsTests/AuthStateTests.swift
git commit -m "feat: add AuthState enum

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: TokenStore (Keychain wrapper)

**Files:**
- Create: `CCUsageStats/CCUsageStats/Auth/TokenStore.swift`
- Create: `CCUsageStats/CCUsageStatsTests/TokenStoreTests.swift`

- [ ] **Step 3.1: Write the failing test**

```swift
import XCTest
@testable import CCUsageStats

final class TokenStoreTests: XCTestCase {
    override func setUpWithError() throws {
        try? TokenStore.delete()
    }
    override func tearDownWithError() throws {
        try? TokenStore.delete()
    }

    func testReadAbsentReturnsNil() {
        XCTAssertNil(TokenStore.read())
    }

    func testWriteThenRead() throws {
        try TokenStore.write("sk-ant-oat01-test")
        XCTAssertEqual(TokenStore.read(), "sk-ant-oat01-test")
    }

    func testOverwrite() throws {
        try TokenStore.write("sk-ant-oat01-old")
        try TokenStore.write("sk-ant-oat01-new")
        XCTAssertEqual(TokenStore.read(), "sk-ant-oat01-new")
    }

    func testDelete() throws {
        try TokenStore.write("sk-ant-oat01-test")
        try TokenStore.delete()
        XCTAssertNil(TokenStore.read())
    }

    func testDeleteAbsentDoesNotThrow() {
        XCTAssertNoThrow(try TokenStore.delete())
    }
}
```

- [ ] **Step 3.2: Run, expect FAIL.**

- [ ] **Step 3.3: Implementation**

```swift
import Foundation
import Security

enum TokenStore {
    static let serviceName = "cc-usage-stats"
    static let account = "oauth-token"

    enum TokenStoreError: Error { case unexpectedStatus(OSStatus) }

    static func read() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { return nil }
        return token
    }

    static func write(_ token: String) throws {
        let data = Data(token.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]

        // Try update first.
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw TokenStoreError.unexpectedStatus(updateStatus)
        }

        // Add new.
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TokenStoreError.unexpectedStatus(addStatus)
        }
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else {
            throw TokenStoreError.unexpectedStatus(status)
        }
    }
}
```

- [ ] **Step 3.4: Run tests**

`xcodebuild test ... -only-testing:CCUsageStatsTests/TokenStoreTests` — expect 5/5 PASS.

Note: tests touch the user's actual login keychain. The setUp/tearDown delete a service entry that this app owns — safe.

- [ ] **Step 3.5: Commit**

```bash
git add CCUsageStats/CCUsageStats/Auth/TokenStore.swift CCUsageStats/CCUsageStatsTests/TokenStoreTests.swift
git commit -m "feat: add TokenStore Keychain wrapper for OAuth token

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: ClaudeCodeKeychainProbe

**Files:**
- Create: `CCUsageStats/CCUsageStats/Auth/ClaudeCodeKeychainProbe.swift`

No automated test — Keychain access prompts can't be exercised in CI. Manual smoke only.

- [ ] **Step 4.1: Implementation**

```swift
import Foundation
import Security

/// One-shot best-effort read of the existing Claude Code OAuth token from
/// macOS Keychain. Returns nil if absent, denied, or the value is not a
/// recognizable OAuth token. macOS surfaces a system access prompt the
/// first time another process queries that entry.
enum ClaudeCodeKeychainProbe {
    private static let service = "Claude Code-credentials"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Claude Code may store either the bare token string or a JSON envelope.
        let candidate = extractToken(from: raw)
        guard let token = candidate, token.hasPrefix("sk-ant-oat01-") else {
            return nil
        }
        return token
    }

    private static func extractToken(from raw: String) -> String? {
        // Bare token? Return as-is.
        if raw.hasPrefix("sk-ant-") { return raw }

        // JSON object? Look for common keys.
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["accessToken", "access_token", "oauth_token", "token"] {
            if let v = obj[key] as? String { return v }
        }
        return nil
    }
}
```

- [ ] **Step 4.2: Manual smoke**

(Deferred to Task 13 end-to-end smoke; cannot script the Keychain prompt.)

- [ ] **Step 4.3: Commit**

```bash
git add CCUsageStats/CCUsageStats/Auth/ClaudeCodeKeychainProbe.swift
git commit -m "feat: add ClaudeCodeKeychainProbe for token auto-discovery

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Phase1Cleanup migration

**Files:**
- Create: `CCUsageStats/CCUsageStats/Migration/Phase1Cleanup.swift`
- Create: `CCUsageStats/CCUsageStatsTests/Phase1CleanupTests.swift`

- [ ] **Step 5.1: Write the failing tests**

```swift
import XCTest
@testable import CCUsageStats

final class Phase1CleanupTests: XCTestCase {
    private var dir: URL!
    private var settings: URL!
    private var config: URL!
    private var sentinel: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings = dir.appendingPathComponent("settings.json")
        config = dir.appendingPathComponent("config.json")
        sentinel = dir.appendingPathComponent("v2-migrated")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testRunWithSentinelIsNoop() throws {
        try Data().write(to: sentinel)
        try Data(#"{"statusLine":{"command":"/path/to/cc-usage-stats statusline","type":"command"}}"#.utf8).write(to: settings)
        try Phase1Cleanup.run(settingsURL: settings, configURL: config, sentinelURL: sentinel)
        // Settings file untouched.
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertNotNil(parsed["statusLine"])
    }

    func testRestoresWrappedCommandWhenInstalled() throws {
        let original: [String: Any] = [
            "statusLine": ["command": "/path/to/cc-usage-stats statusline", "type": "command"],
            "env": ["FOO": "BAR"]
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)
        try Data(#"{"wrappedCommand":"bash /path/to/caveman.sh"}"#.utf8).write(to: config)

        try Phase1Cleanup.run(settingsURL: settings, configURL: config, sentinelURL: sentinel)

        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertEqual((parsed["statusLine"] as! [String: Any])["command"] as? String, "bash /path/to/caveman.sh")
        XCTAssertEqual((parsed["env"] as! [String: Any])["FOO"] as? String, "BAR")
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path), "config.json should be deleted after migration")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testRemovesStatusLineWhenWrappedCommandNullAndOurCommand() throws {
        let original: [String: Any] = [
            "statusLine": ["command": "/path/to/cc-usage-stats statusline", "type": "command"]
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)
        try Data(#"{"wrappedCommand":null}"#.utf8).write(to: config)

        try Phase1Cleanup.run(settingsURL: settings, configURL: config, sentinelURL: sentinel)

        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertNil(parsed["statusLine"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testLeavesUnrelatedStatusLineAlone() throws {
        let original: [String: Any] = [
            "statusLine": ["command": "/path/to/some-other-tool", "type": "command"]
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)

        try Phase1Cleanup.run(settingsURL: settings, configURL: config, sentinelURL: sentinel)

        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertEqual((parsed["statusLine"] as! [String: Any])["command"] as? String, "/path/to/some-other-tool")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testHandlesMissingSettingsFile() throws {
        try Phase1Cleanup.run(settingsURL: settings, configURL: config, sentinelURL: sentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }
}
```

- [ ] **Step 5.2: Run, verify failure (Phase1Cleanup undefined).**

- [ ] **Step 5.3: Implementation**

```swift
import Foundation

enum Phase1Cleanup {
    private static let suffix = " statusline"

    static func run(settingsURL: URL, configURL: URL, sentinelURL: URL) throws {
        if FileManager.default.fileExists(atPath: sentinelURL.path) { return }
        defer { try? touchSentinel(sentinelURL) }

        guard var dict = try readDictionary(settingsURL) else { return }
        guard let sl = dict["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String,
              cmd.hasSuffix(suffix) else {
            return // not our integration; leave alone
        }

        // Determine restoration target from config.json (best effort).
        let wrappedCommand: String? = {
            guard let data = try? Data(contentsOf: configURL),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            // wrappedCommand: explicit null -> nil; missing -> nil; string -> value
            if let v = obj["wrappedCommand"] as? String, !v.isEmpty { return v }
            return nil
        }()

        if let wrapped = wrappedCommand {
            dict["statusLine"] = ["type": "command", "command": wrapped]
        } else {
            dict.removeValue(forKey: "statusLine")
        }

        try writeDictionary(dict, to: settingsURL)
        try? FileManager.default.removeItem(at: configURL)
    }

    private static func readDictionary(_ url: URL) throws -> [String: Any]? {
        let resolved = URL(fileURLWithPath: url.resolvingSymlinksInPath().path)
        guard let data = try? Data(contentsOf: resolved), !data.isEmpty else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func writeDictionary(_ dict: [String: Any], to url: URL) throws {
        let resolved = URL(fileURLWithPath: url.resolvingSymlinksInPath().path)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        let tmp = resolved.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(resolved, withItemAt: tmp)
    }

    private static func touchSentinel(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }
}
```

- [ ] **Step 5.4: Run tests, expect 5/5 PASS.**

- [ ] **Step 5.5: Commit**

```bash
git add CCUsageStats/CCUsageStats/Migration/Phase1Cleanup.swift CCUsageStats/CCUsageStatsTests/Phase1CleanupTests.swift
git commit -m "feat: add Phase 1 cleanup migration for v2.0 first launch

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: AnthropicAPI client + parser

**Files:**
- Create: `CCUsageStats/CCUsageStats/Poller/AnthropicAPI.swift`
- Create: `CCUsageStats/CCUsageStatsTests/AnthropicAPITests.swift`

**Pre-condition:** Task 1 verification complete. Field names below assume the schema documented in the Phase 1 spec (`five_hour.used_percentage` Double, `five_hour.resets_at` Int64 epoch). If Task 1 reveals different field names, adjust the decoder accordingly **before** writing tests.

- [ ] **Step 6.1: Define the protocol so UsagePoller can stub it**

```swift
protocol AnthropicAPIClient {
    func fetchRateLimits() async -> AnthropicAPI.Result
}
```

- [ ] **Step 6.2: Write the failing tests**

```swift
import XCTest
@testable import CCUsageStats

final class AnthropicAPITests: XCTestCase {
    private func sampleBody(withRateLimits: Bool, includeFiveHour: Bool = true) -> Data {
        var rateLimits: [String: Any] = [:]
        if includeFiveHour {
            rateLimits["five_hour"] = ["used_percentage": 42.7, "resets_at": 1714075200]
        }
        rateLimits["seven_day"] = ["used_percentage": 18.3, "resets_at": 1714665600]
        var body: [String: Any] = [
            "id": "msg_x", "type": "message", "role": "assistant",
            "content": [["type": "text", "text": ""]], "model": "claude-haiku-4-5", "stop_reason": "end_turn"
        ]
        if withRateLimits { body["rate_limits"] = rateLimits }
        return try! JSONSerialization.data(withJSONObject: body)
    }

    func testParseBodyWithRateLimits() throws {
        let body = sampleBody(withRateLimits: true)
        let result = AnthropicAPI.parse(status: 200, headers: [:], body: body)
        guard case let .success(snap) = result else { return XCTFail() }
        XCTAssertEqual(snap.fiveHour?.usedPercentage, 42.7, accuracy: 0.001)
        XCTAssertEqual(snap.sevenDay?.usedPercentage, 18.3, accuracy: 0.001)
    }

    func testParseHeadersWhenBodyMissing() throws {
        let body = sampleBody(withRateLimits: false)
        let headers: [String: String] = [
            "anthropic-ratelimit-five-hour-percentage": "55.5",
            "anthropic-ratelimit-five-hour-resets-at": "1714075200",
            "anthropic-ratelimit-seven-day-percentage": "20.0",
            "anthropic-ratelimit-seven-day-resets-at": "1714665600"
        ]
        let result = AnthropicAPI.parse(status: 200, headers: headers, body: body)
        guard case let .success(snap) = result else { return XCTFail() }
        XCTAssertEqual(snap.fiveHour?.usedPercentage, 55.5, accuracy: 0.001)
        XCTAssertEqual(snap.fiveHour?.resetsAt, 1714075200)
        XCTAssertEqual(snap.sevenDay?.usedPercentage, 20.0, accuracy: 0.001)
    }

    func testNoRateLimitsAnywhereYieldsNotSubscriber() {
        let body = sampleBody(withRateLimits: false)
        let result = AnthropicAPI.parse(status: 200, headers: [:], body: body)
        if case .notSubscriber = result { return }
        XCTFail("expected .notSubscriber, got \(result)")
    }

    func test401YieldsInvalidToken() {
        let result = AnthropicAPI.parse(status: 401, headers: [:], body: Data())
        if case .invalidToken = result { return }
        XCTFail("expected .invalidToken, got \(result)")
    }

    func test403YieldsInvalidToken() {
        let result = AnthropicAPI.parse(status: 403, headers: [:], body: Data())
        if case .invalidToken = result { return }
        XCTFail()
    }

    func test429YieldsRateLimited() {
        let result = AnthropicAPI.parse(status: 429, headers: [:], body: Data())
        if case .rateLimited = result { return }
        XCTFail()
    }

    func testMalformedBodyYieldsTransient() {
        let result = AnthropicAPI.parse(status: 200, headers: [:], body: Data("garbage".utf8))
        if case .transient = result { return }
        XCTFail()
    }
}
```

- [ ] **Step 6.3: Run, expect FAIL (AnthropicAPI undefined).**

- [ ] **Step 6.4: Implementation**

```swift
import Foundation

enum AnthropicAPI {
    enum Result: Equatable {
        case success(RateLimitsSnapshot)
        case invalidToken
        case notSubscriber
        case rateLimited
        case transient(String) // network, malformed body, 5xx
    }

    static func parse(status: Int, headers: [String: String], body: Data) -> Result {
        switch status {
        case 401, 403:
            return .invalidToken
        case 429:
            return .rateLimited
        case 200:
            // Path A: JSON body.
            if let bodySnapshot = parseBody(body) {
                return .success(bodySnapshot)
            }
            // Path B: response headers.
            if let headerSnapshot = parseHeaders(headers) {
                return .success(headerSnapshot)
            }
            // 200 with no rate limit info anywhere — likely non-subscriber token.
            // But ensure the body was at least a valid message envelope.
            if (try? JSONSerialization.jsonObject(with: body)) != nil {
                return .notSubscriber
            }
            return .transient("malformed 200 body")
        case 500...599:
            return .transient("server \(status)")
        default:
            return .transient("status \(status)")
        }
    }

    // MARK: - body path

    private static func parseBody(_ data: Data) -> RateLimitsSnapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rl = obj["rate_limits"] as? [String: Any] else {
            return nil
        }
        return RateLimitsSnapshot(
            fiveHour: window(from: rl["five_hour"]),
            sevenDay: window(from: rl["seven_day"])
        )
    }

    private static func window(from any: Any?) -> WindowSnapshot? {
        guard let dict = any as? [String: Any] else { return nil }
        // JSONSerialization decodes JSON numbers as NSNumber.
        guard let pctNum = dict["used_percentage"] as? NSNumber,
              let resetNum = dict["resets_at"] as? NSNumber else {
            return nil
        }
        return WindowSnapshot(usedPercentage: pctNum.doubleValue, resetsAt: resetNum.int64Value)
    }

    // MARK: - header path

    private static func parseHeaders(_ headers: [String: String]) -> RateLimitsSnapshot? {
        let lc = headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }

        let five = window(headers: lc, prefix: "anthropic-ratelimit-five-hour")
        let seven = window(headers: lc, prefix: "anthropic-ratelimit-seven-day")
        if five == nil && seven == nil { return nil }
        return RateLimitsSnapshot(fiveHour: five, sevenDay: seven)
    }

    private static func window(headers: [String: String], prefix: String) -> WindowSnapshot? {
        guard let pctStr = headers["\(prefix)-percentage"],
              let pct = Double(pctStr),
              let resetStr = headers["\(prefix)-resets-at"],
              let reset = Int64(resetStr) else {
            return nil
        }
        return WindowSnapshot(usedPercentage: pct, resetsAt: reset)
    }
}

/// Live HTTP implementation. Tests use `AnthropicAPI.parse` directly.
struct LiveAnthropicAPIClient: AnthropicAPIClient {
    let token: String
    let session: URLSession
    let model: String
    let useBetaHeader: Bool

    init(token: String, session: URLSession = .shared, model: String = "claude-haiku-4-5", useBetaHeader: Bool = false) {
        self.token = token
        self.session = session
        self.model = model
        self.useBetaHeader = useBetaHeader
    }

    func fetchRateLimits() async -> AnthropicAPI.Result {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if useBetaHeader { req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta") }
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "."]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .transient("no http response") }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { acc, kv in
                if let k = kv.key as? String, let v = kv.value as? String { acc[k] = v }
            }
            return AnthropicAPI.parse(status: http.statusCode, headers: headers, body: data)
        } catch {
            return .transient(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 6.5: Run tests, expect 7/7 PASS.**

- [ ] **Step 6.6: Add Haiku→Sonnet model fallback**

Anthropic may reject the cheaper Haiku model on some plan tiers with a 400. Add a fallback to `claude-sonnet-4-5` for the next call only, recorded by `LiveAnthropicAPIClient`:

```swift
struct LiveAnthropicAPIClient: AnthropicAPIClient {
    let token: String
    let session: URLSession
    var preferredModel: String = "claude-haiku-4-5"
    let fallbackModel: String = "claude-sonnet-4-5"
    let useBetaHeader: Bool

    // ... existing init etc.

    func fetchRateLimits() async -> AnthropicAPI.Result {
        let first = await fetch(model: preferredModel)
        if case .transient(let msg) = first, msg.contains("model") {
            return await fetch(model: fallbackModel)
        }
        return first
    }

    private func fetch(model: String) async -> AnthropicAPI.Result {
        // existing body of fetchRateLimits, parameterized on `model`
    }
}
```

(Detection heuristic: Anthropic's 400 response typically includes "model" in the JSON error message. If the heuristic is unreliable, plan Task 1 verification can refine the trigger string.)

- [ ] **Step 6.7: Commit**

```bash
git add CCUsageStats/CCUsageStats/Poller/AnthropicAPI.swift CCUsageStats/CCUsageStatsTests/AnthropicAPITests.swift
git commit -m "feat: add AnthropicAPI client with body+header rate-limit parsing

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: UsagePoller state machine

**Files:**
- Create: `CCUsageStats/CCUsageStats/Poller/UsagePoller.swift`
- Create: `CCUsageStats/CCUsageStatsTests/UsagePollerTests.swift`

The poller uses an injected `AnthropicAPIClient`. Tests pass a stub.

- [ ] **Step 7.1: Write the failing tests**

```swift
import XCTest
@testable import CCUsageStats

@MainActor
final class UsagePollerTests: XCTestCase {
    final class StubAPI: AnthropicAPIClient {
        var queue: [AnthropicAPI.Result] = []
        var calls = 0
        func fetchRateLimits() async -> AnthropicAPI.Result {
            calls += 1
            return queue.isEmpty ? .transient("empty") : queue.removeFirst()
        }
    }

    private var tmpStateFile: URL!
    override func setUp() {
        tmpStateFile = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID()).json")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmpStateFile) }

    func testSuccessUpdatesCacheAndAuthOk() async throws {
        let api = StubAPI()
        api.queue = [.success(.init(
            fiveHour: WindowSnapshot(usedPercentage: 42, resetsAt: 100),
            sevenDay: WindowSnapshot(usedPercentage: 18, resetsAt: 200)))]
        let poller = UsagePoller(api: api, cacheURL: tmpStateFile, clock: { 1000 })

        await poller.tickForTest()

        XCTAssertEqual(poller.authState, .ok)
        let cached = try CacheStore.read(at: tmpStateFile)
        XCTAssertEqual(cached?.snapshot.fiveHour?.usedPercentage, 42)
    }

    func testInvalidTokenSetsStateAndStops() async {
        let api = StubAPI(); api.queue = [.invalidToken]
        let poller = UsagePoller(api: api, cacheURL: tmpStateFile, clock: { 1 })
        await poller.tickForTest()
        XCTAssertEqual(poller.authState, .invalidToken)
        XCTAssertFalse(poller.isPolling)
    }

    func testNotSubscriberSetsStateAndStops() async {
        let api = StubAPI(); api.queue = [.notSubscriber]
        let poller = UsagePoller(api: api, cacheURL: tmpStateFile, clock: { 1 })
        await poller.tickForTest()
        XCTAssertEqual(poller.authState, .notSubscriber)
        XCTAssertFalse(poller.isPolling)
    }

    func testFiveTransientFailuresSetOffline() async {
        let api = StubAPI(); api.queue = Array(repeating: .transient("x"), count: 5)
        let poller = UsagePoller(api: api, cacheURL: tmpStateFile, clock: { 1 })
        for _ in 0..<5 { await poller.tickForTest() }
        XCTAssertEqual(poller.authState, .offline)
        XCTAssertTrue(poller.isPolling, "transient stays polling")
    }

    func testSuccessAfterOfflineRecovers() async {
        let api = StubAPI()
        api.queue = Array(repeating: .transient("x"), count: 5) + [.success(.init(
            fiveHour: WindowSnapshot(usedPercentage: 5, resetsAt: 0), sevenDay: nil))]
        let poller = UsagePoller(api: api, cacheURL: tmpStateFile, clock: { 1 })
        for _ in 0..<6 { await poller.tickForTest() }
        XCTAssertEqual(poller.authState, .ok)
    }

    func testRateLimitedTriggersBackoff() async {
        // Initial value is 60 (base interval). First 429 doubles to 120, second
        // to 240, third to 480 (still under the 600 cap).
        let api = StubAPI(); api.queue = [.rateLimited, .rateLimited, .rateLimited]
        let poller = UsagePoller(api: api, cacheURL: tmpStateFile, clock: { 1 })
        XCTAssertEqual(poller.currentBackoffSeconds, 60, "initial value before any tick")
        await poller.tickForTest()
        XCTAssertEqual(poller.currentBackoffSeconds, 120)
        await poller.tickForTest()
        XCTAssertEqual(poller.currentBackoffSeconds, 240)
        await poller.tickForTest()
        XCTAssertEqual(poller.currentBackoffSeconds, 480)
    }

    func testBackoffResetsOnSuccess() async {
        let api = StubAPI()
        api.queue = [.rateLimited, .rateLimited, .success(.init(
            fiveHour: WindowSnapshot(usedPercentage: 1, resetsAt: 0), sevenDay: nil))]
        let poller = UsagePoller(api: api, cacheURL: tmpStateFile, clock: { 1 })
        await poller.tickForTest()
        await poller.tickForTest()
        await poller.tickForTest()
        XCTAssertEqual(poller.currentBackoffSeconds, 60)
    }
}
```

- [ ] **Step 7.2: Run, expect FAIL.**

- [ ] **Step 7.3: Implementation**

```swift
import Foundation
import os

@MainActor
final class UsagePoller: ObservableObject {
    private static let log = Logger(subsystem: "dev.dv.ccusagestats", category: "poller")
    private let api: AnthropicAPIClient
    private let cacheURL: URL
    private let clock: () -> Int64

    @Published private(set) var authState: AuthState = .unknown
    @Published private(set) var isPolling = false
    private(set) var transientFailureCount = 0
    private(set) var currentBackoffSeconds: TimeInterval = 60

    private var timer: Timer?
    private static let baseInterval: TimeInterval = 60
    private static let maxBackoff: TimeInterval = 600
    private static let offlineThreshold = 5

    init(api: AnthropicAPIClient, cacheURL: URL, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.api = api
        self.cacheURL = cacheURL
        self.clock = clock
    }

    func start() {
        guard !isPolling else { return }
        isPolling = true
        currentBackoffSeconds = Self.baseInterval
        Task { @MainActor in await tick() }
        scheduleTimer(after: Self.baseInterval)
    }

    func stop() {
        isPolling = false
        timer?.invalidate()
        timer = nil
    }

    /// For tests — single tick without timers.
    func tickForTest() async { await tick() }

    private func tick() async {
        let result = await api.fetchRateLimits()
        switch result {
        case .success(let snapshot):
            try? CacheStore.update(at: cacheURL, with: snapshot, now: clock())
            authState = .ok
            transientFailureCount = 0
            currentBackoffSeconds = Self.baseInterval

        case .invalidToken:
            authState = .invalidToken
            stop()

        case .notSubscriber:
            authState = .notSubscriber
            stop()

        case .rateLimited:
            currentBackoffSeconds = min(Self.maxBackoff, currentBackoffSeconds * 2)
            // Don't change authState — we're still polling, just slowed.

        case .transient(let msg):
            Self.log.warning("transient: \(msg, privacy: .public)")
            transientFailureCount += 1
            if transientFailureCount >= Self.offlineThreshold {
                authState = .offline
            }
        }
    }

    private func scheduleTimer(after seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPolling else { return }
                await self.tick()
                // Reschedule with current backoff in case it changed.
                self.scheduleTimer(after: self.currentBackoffSeconds)
            }
        }
    }
}
```

- [ ] **Step 7.4: Run tests, expect 7/7 PASS.**

- [ ] **Step 7.5: Commit**

```bash
git add CCUsageStats/CCUsageStats/Poller/UsagePoller.swift CCUsageStats/CCUsageStatsTests/UsagePollerTests.swift
git commit -m "feat: add UsagePoller state machine with backoff and offline detection

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: SettingsWindow

**Files:**
- Create: `CCUsageStats/CCUsageStats/Auth/SettingsWindow.swift`

No automated tests — SwiftUI window UI. Manual smoke covers it.

- [ ] **Step 8.1: Implementation**

```swift
import SwiftUI
import AppKit

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var hostingController: NSHostingController<SettingsView>?

    func show(viewModel: SettingsViewModel) {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }

        let host = NSHostingController(rootView: SettingsView(vm: viewModel) { [weak self] in
            self?.window?.performClose(nil)
        })
        let win = NSWindow(contentViewController: host)
        win.title = "Set OAuth Token"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 480, height: 220))
        win.center()
        win.isReleasedWhenClosed = false
        self.window = win
        self.hostingController = host
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var token: String = ""
    @Published var error: String?
    @Published var busy = false

    private let onSaveSuccess: (String) -> Void
    init(onSaveSuccess: @escaping (String) -> Void) { self.onSaveSuccess = onSaveSuccess }

    func tryClaudeCodeKeychain() {
        if let t = ClaudeCodeKeychainProbe.read() {
            token = t
            error = nil
        } else {
            error = "Couldn't read Claude Code keychain entry. Allow access in the system prompt, or paste manually."
        }
    }

    /// Returns true if window should close.
    /// `testFire` is given the trimmed token and is responsible for using it.
    func saveAndTest(testFire: (String) async -> AnthropicAPI.Result) async -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("sk-ant-oat01-") else {
            if t.hasPrefix("sk-ant-api03-") {
                error = "Use a long-lived OAuth token from `claude setup-token`, not an API key."
            } else {
                error = "Token must start with sk-ant-oat01-"
            }
            return false
        }
        // Normalize stored value too.
        token = t
        busy = true
        defer { busy = false }
        do { try TokenStore.write(t) }
        catch { self.error = "Keychain write failed: \(error)"; return false }

        let result = await testFire(t)
        switch result {
        case .success, .notSubscriber:
            // .notSubscriber is still a valid token (we tested it answered) — caller decides UI.
            onSaveSuccess(t); return true
        case .invalidToken:
            self.error = "Anthropic rejected the token (401/403). Check it and try again."
            return false
        case .rateLimited, .transient:
            self.error = "Couldn't verify token (network or rate-limit). Saved anyway; the poller will retry."
            onSaveSuccess(t); return true
        }
    }
}

struct SettingsView: View {
    @ObservedObject var vm: SettingsViewModel
    let onClose: () -> Void

    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste your long-lived OAuth token from `claude setup-token`. Stored securely in macOS Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("sk-ant-oat01-…", text: $vm.token)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Paste from Claude Code Keychain") { vm.tryClaudeCodeKeychain() }
                Spacer()
            }
            if let err = vm.error {
                Text(err).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(saving ? "Testing…" : "Save & Test") {
                    saving = true
                    Task {
                        let close = await vm.saveAndTest { t in
                            await LiveAnthropicAPIClient(token: t).fetchRateLimits()
                        }
                        saving = false
                        if close { onClose() }
                    }
                }
                .disabled(vm.token.isEmpty || saving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480)
    }
}
```

- [ ] **Step 8.2: Build only**

`xcodebuild build -scheme CCUsageStats -destination 'platform=macOS' -project CCUsageStats/CCUsageStats.xcodeproj 2>&1 | tail -10` — expect `** BUILD SUCCEEDED **`.

- [ ] **Step 8.3: Commit**

```bash
git add CCUsageStats/CCUsageStats/Auth/SettingsWindow.swift
git commit -m "feat: add SettingsWindow for OAuth token entry

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Rewrite MenuViewModel + MenuBarContent

**Files:**
- Modify: `CCUsageStats/CCUsageStats/Tray/MenuViewModel.swift`
- Modify: `CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift`

This is the biggest change. The new viewmodel owns a `UsagePoller`, exposes `authState` and `displayState`, and has methods to open the SettingsWindow. The old install/uninstall/path-mismatch/cache-watcher state is removed.

- [ ] **Step 9.1: Replace `MenuViewModel.swift` body**

```swift
import Foundation
import Combine

@MainActor
final class MenuViewModel: ObservableObject {
    @Published private(set) var displayState: DisplayState = .init(
        menuBarText: "—", tier: .neutral, isStale: false, hasFiveHourData: false
    )
    @Published private(set) var cached: CachedState?
    @Published private(set) var authState: AuthState = .unknown
    @Published var launchAtLogin: Bool = LaunchAtLoginService.isEnabled
    @Published var lastError: String?

    private var poller: UsagePoller?
    private var clockTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    func start() {
        guard poller == nil else { return }
        // Load any cache from previous run.
        reloadCache()

        // Discover token.
        let token: String? = TokenStore.read() ?? {
            // Try Claude Code keychain once.
            if let probed = ClaudeCodeKeychainProbe.read() {
                try? TokenStore.write(probed)
                return probed
            }
            return nil
        }()

        if let token {
            let api = LiveAnthropicAPIClient(token: token)
            let p = UsagePoller(api: api, cacheURL: Paths.stateFile)
            // Mirror published state + reload cache after each tick.
            p.$authState
                .receive(on: RunLoop.main)
                .sink { [weak self] in
                    self?.authState = $0
                    self?.reloadCache()
                }
                .store(in: &cancellables)
            poller = p
            p.start()
        } else {
            authState = .invalidToken
        }

        // Tick once a minute so freshness/countdowns update without a write.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recomputeFromCachedOnly() }
        }
    }

    func stop() {
        poller?.stop(); poller = nil
        clockTimer?.invalidate(); clockTimer = nil
        cancellables.removeAll()
    }

    func openSettings() {
        let vm = SettingsViewModel { [weak self] _ in
            self?.restartPolling()
        }
        SettingsWindowController.shared.show(viewModel: vm)
    }

    func resetToken() {
        try? TokenStore.delete()
        authState = .invalidToken
        poller?.stop(); poller = nil
        openSettings()
    }

    func toggleLaunchAtLogin() {
        let newValue = !launchAtLogin
        do { try LaunchAtLoginService.setEnabled(newValue); launchAtLogin = newValue }
        catch { lastError = "Launch-at-login toggle failed: \(error)" }
    }

    private func restartPolling() {
        poller?.stop(); poller = nil
        cancellables.removeAll()
        guard let token = TokenStore.read() else { authState = .invalidToken; return }
        let api = LiveAnthropicAPIClient(token: token)
        let p = UsagePoller(api: api, cacheURL: Paths.stateFile)
        p.$authState
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.authState = $0
                self?.reloadCache()
            }
            .store(in: &cancellables)
        poller = p
        p.start()
    }

    private func reloadCache() {
        cached = (try? CacheStore.read(at: Paths.stateFile)) ?? nil
        recomputeFromCachedOnly()
    }

    private func recomputeFromCachedOnly() {
        let now = Int64(Date().timeIntervalSince1970)
        displayState = DisplayState.compute(now: now, cached: cached)
    }
}
```

- [ ] **Step 9.2: Replace `MenuBarContent.swift` body**

```swift
import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @ObservedObject var vm: MenuViewModel
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: glyph()).symbolRenderingMode(.hierarchical).foregroundStyle(color())
            if vm.authState != .invalidToken {
                Text(vm.displayState.menuBarText)
                    .opacity(vm.displayState.isStale ? 0.5 : 1.0)
                    .monospacedDigit()
            }
        }
    }

    private func glyph() -> String {
        switch vm.authState {
        case .invalidToken: return "exclamationmark.gauge"
        case .notSubscriber: return "gauge.with.dots.needle.0percent"
        default: switch vm.displayState.tier {
            case .neutral: return "gauge.with.dots.needle.33percent"
            case .warning: return "gauge.with.dots.needle.50percent"
            case .danger: return "gauge.with.dots.needle.67percent"
        }
        }
    }

    private func color() -> Color {
        switch vm.authState {
        case .invalidToken: return .red
        case .notSubscriber: return .secondary
        case .offline, .ok, .unknown: break // last-known tier color (per spec)
        }
        if vm.displayState.isStale { return .secondary }
        switch vm.displayState.tier {
        case .neutral: return .primary
        case .warning: return .yellow
        case .danger: return .red
        }
    }
}

struct MenuBarDropdown: View {
    @ObservedObject var vm: MenuViewModel
    var body: some View {
        if let cached = vm.cached {
            WindowRow(title: "5h session", window: cached.snapshot.fiveHour, now: now)
            WindowRow(title: "7-day window", window: cached.snapshot.sevenDay, now: now)
            Divider()
            Text("Last update \(RelativeTime.format(seconds: now - cached.capturedAt)) ago")
                .foregroundStyle(.secondary)
        } else {
            Text("No data captured yet.").foregroundStyle(.secondary)
        }
        Divider()
        authStatusRow
        if let err = vm.lastError { Text(err).foregroundStyle(.red).font(.caption) }

        Divider()
        Toggle("Launch at Login", isOn: Binding(
            get: { vm.launchAtLogin },
            set: { _ in vm.toggleLaunchAtLogin() }
        ))
        if vm.authState == .invalidToken || TokenStore.read() == nil {
            Button("Set Token…") { vm.openSettings() }
        } else {
            Button("Reset Token…") { vm.resetToken() }
        }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var now: Int64 { Int64(Date().timeIntervalSince1970) }

    @ViewBuilder
    private var authStatusRow: some View {
        switch vm.authState {
        case .invalidToken:
            Text("Token rejected. Set Token…").foregroundStyle(.red).font(.caption)
        case .notSubscriber:
            Text("No Claude.ai subscription rate-limit data.").foregroundStyle(.secondary).font(.caption)
        case .offline:
            Text("Offline").foregroundStyle(.secondary).font(.caption)
        case .ok, .unknown:
            EmptyView()
        }
    }
}

private struct WindowRow: View {
    let title: String
    let window: WindowSnapshot?
    let now: Int64
    var body: some View {
        if let w = window {
            let pct = Int(w.usedPercentage.rounded())
            let delta = w.resetsAt - now
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title): \(pct)%")
                Text(resetCaption(delta: delta)).foregroundStyle(.secondary).font(.caption)
            }
        } else {
            Text("\(title): not yet observed").foregroundStyle(.secondary)
        }
    }

    private func resetCaption(delta: Int64) -> String {
        if delta >= 0 { return "resets in \(RelativeTime.format(seconds: delta)) ago".replacingOccurrences(of: " ago", with: "") }
        else { return "reset \(RelativeTime.format(seconds: -delta)) ago, awaiting fresh data" }
    }
}
```

(Note: keep the existing `resetCaption` semantics from Phase 1 — show "resets in Xh Ym" until the moment passes, then "reset Xm ago, awaiting fresh data".)

- [ ] **Step 9.3: Build, expect SUCCESS.**

- [ ] **Step 9.4: Commit**

```bash
git add CCUsageStats/CCUsageStats/Tray/MenuViewModel.swift CCUsageStats/CCUsageStats/Tray/MenuBarContent.swift
git commit -m "feat: rewire MenuViewModel/MenuBarContent for poller-based auth

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Wire Phase 1 cleanup + token discovery in CCUsageStatsApp

**Files:**
- Modify: `CCUsageStats/CCUsageStats/CCUsageStatsApp.swift`

- [ ] **Step 10.1: Replace `CCUsageStatsApp.swift` body**

```swift
import SwiftUI

@main
struct CCUsageStatsApp: App {
    @StateObject private var vm = MenuViewModel()

    init() {
        // Phase 1 cleanup migration. One-shot; sentinel guards re-runs.
        try? Phase1Cleanup.run(
            settingsURL: Paths.claudeSettings,
            configURL: Paths.configFile,
            sentinelURL: Paths.appSupportDir.appendingPathComponent("v2-migrated")
        )
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarDropdown(vm: vm)
                .onAppear {
                    vm.start()
                }
        } label: {
            MenuBarLabel(vm: vm)
        }
        .menuBarExtraStyle(.menu)
    }
}
```

The `argv[1] == "statusline"` branch is gone.

- [ ] **Step 10.2: Build, expect SUCCESS.**

- [ ] **Step 10.3: Commit**

```bash
git add CCUsageStats/CCUsageStats/CCUsageStatsApp.swift
git commit -m "feat: run Phase1Cleanup at app launch, drop statusline mode

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Delete Phase 1 source files

**Files (delete):**
- `CCUsageStats/CCUsageStats/Statusline/StatuslineMode.swift`
- `CCUsageStats/CCUsageStats/Statusline/WrappedCommand.swift`
- `CCUsageStats/CCUsageStats/Tray/Installer.swift`
- `CCUsageStats/CCUsageStats/Tray/CacheWatcher.swift`
- `CCUsageStats/CCUsageStatsTests/StatuslineModeTests.swift`
- `CCUsageStats/CCUsageStatsTests/WrappedCommandTests.swift`
- `CCUsageStats/CCUsageStatsTests/InstallerTests.swift`
- `CCUsageStats/CCUsageStatsTests/CacheWatcherTests.swift`
- `CCUsageStats/CCUsageStatsTests/Fixtures/statusline-*.json` (5 files)

- [ ] **Step 11.1: rm + verify**

```bash
cd /Users/dv/Projects/cc-usage-stats
rm CCUsageStats/CCUsageStats/Statusline/StatuslineMode.swift
rm CCUsageStats/CCUsageStats/Statusline/WrappedCommand.swift
rmdir CCUsageStats/CCUsageStats/Statusline
rm CCUsageStats/CCUsageStats/Tray/Installer.swift
rm CCUsageStats/CCUsageStats/Tray/CacheWatcher.swift
rm CCUsageStats/CCUsageStatsTests/StatuslineModeTests.swift
rm CCUsageStats/CCUsageStatsTests/WrappedCommandTests.swift
rm CCUsageStats/CCUsageStatsTests/InstallerTests.swift
rm CCUsageStats/CCUsageStatsTests/CacheWatcherTests.swift
rm CCUsageStats/CCUsageStatsTests/Fixtures/statusline-*.json
rmdir CCUsageStats/CCUsageStatsTests/Fixtures
```

- [ ] **Step 11.1.5: Stage deletions explicitly**

Per CLAUDE.md, prefer explicit `git add` over `git add -A`. Use:

```bash
git add \
  CCUsageStats/CCUsageStats/Statusline \
  CCUsageStats/CCUsageStats/Tray/Installer.swift \
  CCUsageStats/CCUsageStats/Tray/CacheWatcher.swift \
  CCUsageStats/CCUsageStatsTests/StatuslineModeTests.swift \
  CCUsageStats/CCUsageStatsTests/WrappedCommandTests.swift \
  CCUsageStats/CCUsageStatsTests/InstallerTests.swift \
  CCUsageStats/CCUsageStatsTests/CacheWatcherTests.swift \
  CCUsageStats/CCUsageStatsTests/Fixtures
```

Note: git tracks the deletions when paths no longer exist on disk; explicit listing keeps the audit trail clear.

- [ ] **Step 11.2: Run full test suite**

`xcodebuild test -scheme CCUsageStats -destination 'platform=macOS' -project CCUsageStats/CCUsageStats.xcodeproj 2>&1 | tail -20`

Expect `** TEST SUCCEEDED **` with the new tests (AuthState, TokenStore, Phase1Cleanup, AnthropicAPI, UsagePoller) plus surviving tests (Paths, RateLimits, CacheStore, AppConfig, DisplayState, RelativeTime).

If anything fails because dead references remain, fix forward and reflect changes here.

- [ ] **Step 11.3: Commit (deletions already staged in 11.1.5)**

```bash
git commit -m "chore: remove Phase 1 statusline integration source

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Update README + manual checklist

**Files:**
- Modify: `README.md`
- Modify: `docs/manual-test-checklist.md`

- [ ] **Step 12.1: Rewrite README**

Update the README to describe the new architecture: Anthropic API poller, OAuth token, Settings window. Drop the install/uninstall statusline section. Note privacy: token in Keychain, no other auth. Cost: pennies/month.

- [ ] **Step 12.2: Rewrite manual checklist**

Replace the Phase 1 install/uninstall steps with:

1. Fresh launch with no token → menubar red `!` icon, dropdown "Set Token…".
2. Click "Set Token…" → window opens.
3. Click "Paste from Claude Code Keychain" → keychain prompt appears → allow → token populates.
4. Save & Test → window closes; menubar within ~5s shows real %.
5. Reset Token → window opens with empty field.
6. Paste an API key (`sk-ant-api03-…`) → error "Use a long-lived OAuth token…".
7. Disconnect network → after ~5 min, dropdown shows "Offline" tag.
8. Reconnect → tag clears within 60s.
9. Phase 1 migration: with a previously-installed Phase 1 build, install Phase 2 over the top → `~/.claude/settings.json` is restored to caveman; `config.json` deleted; sentinel created.
10. Launch at Login still toggles correctly.

- [ ] **Step 12.3: Commit**

```bash
git add README.md docs/manual-test-checklist.md
git commit -m "docs: update README and manual checklist for v2 OAuth poller

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: End-to-end smoke

Manual. Run on the user's machine.

- [ ] **Step 13.1: Build a clean Release**

```bash
./scripts/install-dev.sh
```

- [ ] **Step 13.2: Run the manual checklist (Task 12.2 list)**

Note any failures. Fix forward. Each fix gets its own commit.

- [ ] **Step 13.3: Final cleanup**

`git status -s` — must be clean. `git log --oneline` — verify the Phase 2 sequence.

---

## Done

Final state:
- App polls `/v1/messages` every 60s with the user's OAuth token, regardless of whether Claude Code is running.
- Phase 1 statusline integration is fully removed and the user's `~/.claude/settings.json` is restored on first run.
- All XCTest suites green.

## Out of Scope (Reaffirmed)

- Sub-window display (sonnet, opus, cowork).
- API-key support.
- Cross-machine sync.
- Threshold-based notifications.
- Polling-cadence preferences.
- Multi-account.
- A history graph.
