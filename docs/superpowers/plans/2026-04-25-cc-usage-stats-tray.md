# cc-usage-stats Menubar App — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a macOS menubar app that displays Claude Code's server-reported 5h/7d rate-limit usage by intercepting Claude Code's statusline command, caching the JSON to disk, and rendering live updates in the menubar.

**Architecture:** Single Swift binary `cc-usage-stats` with two modes selected by `argv[1]`. Default mode runs a `MenuBarExtra` SwiftUI app that watches a JSON cache file via FSEvents. The `statusline` mode is a stdin filter that Claude Code invokes per prompt — it normalizes the `rate_limits` block into the cache and forwards stdin to a previously-configured statusline command.

**Tech Stack:** Swift 5.9+, SwiftUI (`MenuBarExtra`), AppKit interop where needed, `ServiceManagement` (`SMAppService`) for Launch-at-Login, XCTest for unit tests, Xcode project (macOS 13+ deployment target).

**Spec:** [`docs/superpowers/specs/2026-04-25-cc-usage-stats-tray-design.md`](../specs/2026-04-25-cc-usage-stats-tray-design.md)

---

## File Structure

App sources (Xcode target `CCUsageStats`):

| File | Responsibility |
|------|----------------|
| `App/CCUsageStatsApp.swift` | `@main` entry point, mode dispatch (`argv[1] == "statusline"` → run `StatuslineMode.run(...)` and `exit(0)`; else launch `MenuBarExtra`) |
| `App/Paths.swift` | Computed paths for `state.json`, `config.json`, app support dir, Claude settings; `mkdir -p` helpers |
| `Core/RateLimits.swift` | `WindowSnapshot` + `RateLimitsSnapshot` Codable models; pure parsing from Claude Code stdin JSON |
| `Core/CacheStore.swift` | Read + atomic write of `state.json`; merge-on-write semantics (preserve existing fields when new payload lacks them) |
| `Core/AppConfig.swift` | Read + atomic write of `config.json` (`wrappedCommand` field) |
| `Core/DisplayState.swift` | Pure function `displayState(now:, snapshot:) -> UIState` mapping cache to icon/text/colors/freshness |
| `Statusline/StatuslineMode.swift` | Read stdin, parse, update cache, spawn wrapped command, forward its stdout, never propagate errors to Claude Code |
| `Statusline/WrappedCommand.swift` | Spawn helper: launch `/bin/sh -c "<cmd>"` with stdin pipe, capture stdout, hard timeout |
| `Tray/CacheWatcher.swift` | `DispatchSource.makeFileSystemObjectSource` wrapper publishing change events |
| `Tray/MenuViewModel.swift` | `@MainActor` `ObservableObject` combining cache watcher + clock tick + `DisplayState` |
| `Tray/MenuBarContent.swift` | SwiftUI views for menubar label and dropdown |
| `Tray/Installer.swift` | Read/edit `~/.claude/settings.json` with timestamped backup, symlink-following, atomic rename |
| `Tray/LaunchAtLoginService.swift` | Thin wrapper around `SMAppService.mainApp` |

Tests (Xcode target `CCUsageStatsTests`):

| File | Covers |
|------|--------|
| `Tests/RateLimitsTests.swift` | JSON fixtures: full, only-five-hour, only-seven-day, missing-rate-limits, malformed |
| `Tests/CacheStoreTests.swift` | Read absent, read corrupt, atomic write, merge semantics, concurrent writers |
| `Tests/AppConfigTests.swift` | Read absent, round-trip, wrappedCommand null vs string |
| `Tests/DisplayStateTests.swift` | Fresh / stale / empty / threshold bands |
| `Tests/StatuslineModeTests.swift` | End-to-end with stub stdin and stub wrapped command |
| `Tests/InstallerTests.swift` | Snapshot before/after for empty, simple, symlinked, malformed `settings.json` |

Build / scripts:

| File | Responsibility |
|------|----------------|
| `CCUsageStats.xcodeproj` | Xcode project, two targets, macOS 13.0 deployment, codesign disabled for dev |
| `scripts/build.sh` | `xcodebuild -scheme CCUsageStats -configuration Release -derivedDataPath build` then copy `.app` to `dist/` |
| `scripts/install-dev.sh` | Build + copy `.app` to `~/Applications/` for daily use |
| `.gitignore` | Standard Swift/Xcode + `build/`, `dist/`, `DerivedData/`, `.swiftpm/`, `xcuserdata/` |

---

## Conventions

- **Frequent commits:** every task ends with a commit; never bundle two tasks in one commit.
- **Commit message format:** `feat: ...`, `test: ...`, `chore: ...`, `docs: ...`. Subject ≤ 72 chars. No `Co-Authored-By` line in this project unless the user later asks for it.
- **TDD:** every code task starts with a failing test, then minimal impl. UI / integration tasks that can't be unit-tested have an explicit manual smoke step.
- **Atomic file writes:** always `write to .tmp` then `rename(2)`. Never write in place.
- **No swallowed errors in tray:** any caught exception in tray mode logs via `os_log`. Statusline mode is the opposite — it MUST swallow everything and exit 0.
- **macOS 13.0 deployment target.** No back-compat to 12 or earlier.

---

## Task 1: Project bootstrap

**Files:**
- Create: `CCUsageStats.xcodeproj` (via Xcode UI; the resulting directory will be committed except for `xcuserdata/`)
- Create: `App/CCUsageStatsApp.swift`
- Create: `Tests/CCUsageStatsTests.swift` (placeholder)
- Create: `.gitignore`
- Create: `README.md` (one-paragraph stub linking to spec/plan)

- [ ] **Step 1.1: Create Xcode project**

In Xcode: File → New → Project → macOS → App.
Settings:
- Product Name: `CCUsageStats`
- Organization Identifier: `dev.dv.ccusagestats`
- Interface: **SwiftUI**
- Language: **Swift**
- Storage: None
- Include Tests: **yes**
- Save in `/Users/dv/Projects/cc-usage-stats/`

Then in target settings:
- Deployment target: macOS 13.0
- Signing: "Sign to Run Locally" (development)
- Hardened Runtime: enabled
- App Sandbox: **disabled** (we need to read/write `~/.claude/settings.json` and execute arbitrary statusline subprocesses)

- [ ] **Step 1.2: Mark app as menubar-only (no Dock icon, no main window)**

Edit `Info.plist` (target → Info tab):
- Add `LSUIElement` = `YES` (Application is agent (UIElement)).

Replace `App/CCUsageStatsApp.swift` with:

```swift
import SwiftUI

@main
struct CCUsageStatsApp: App {
    var body: some Scene {
        MenuBarExtra("cc-usage-stats", systemImage: "gauge.with.dots.needle.33percent") {
            Text("placeholder")
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}
```

Delete the auto-generated `ContentView.swift` and any `WindowGroup` reference.

- [ ] **Step 1.3: Build & manually verify**

Run: ⌘R in Xcode.
Expected: a small gauge icon appears in the menubar; no Dock icon; no window. Click reveals a single "placeholder" row + Quit. Quit terminates the app.

- [ ] **Step 1.4: Add `.gitignore`**

```
build/
dist/
DerivedData/
.swiftpm/
*.xcodeproj/xcuserdata/
*.xcodeproj/project.xcworkspace/xcuserdata/
.DS_Store
```

- [ ] **Step 1.5: Add stub `README.md`**

```markdown
# cc-usage-stats

macOS menubar app showing Claude Code session rate-limit usage.

- Spec: [docs/superpowers/specs/2026-04-25-cc-usage-stats-tray-design.md](docs/superpowers/specs/2026-04-25-cc-usage-stats-tray-design.md)
- Implementation plan: [docs/superpowers/plans/2026-04-25-cc-usage-stats-tray.md](docs/superpowers/plans/2026-04-25-cc-usage-stats-tray.md)

Status: in development.
```

- [ ] **Step 1.6: Commit**

```bash
git add CCUsageStats.xcodeproj App Tests .gitignore README.md
git commit -m "chore: bootstrap Xcode menubar app project"
```

---

## Task 2: Paths helper

**Files:**
- Create: `App/Paths.swift`
- Create: `Tests/PathsTests.swift`

- [ ] **Step 2.1: Write the failing test**

`Tests/PathsTests.swift`:

```swift
import XCTest
@testable import CCUsageStats

final class PathsTests: XCTestCase {
    func testStateAndConfigPathsAreUnderApplicationSupport() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        XCTAssertEqual(Paths.appSupportDir.path, appSupport.appendingPathComponent("cc-usage-stats").path)
        XCTAssertEqual(Paths.stateFile.lastPathComponent, "state.json")
        XCTAssertEqual(Paths.configFile.lastPathComponent, "config.json")
    }

    func testClaudeSettingsPathIsUnderHome() {
        XCTAssertTrue(Paths.claudeSettings.path.hasSuffix("/.claude/settings.json"))
    }

    func testEnsureAppSupportDirCreatesDirectory() throws {
        let tmpHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Paths.ensureDirectory(tmpHome)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpHome.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        try FileManager.default.removeItem(at: tmpHome)
    }
}
```

- [ ] **Step 2.2: Run test to verify it fails**

Run: ⌘U (or `xcodebuild test -scheme CCUsageStats -destination 'platform=macOS' -only-testing:CCUsageStatsTests/PathsTests`).
Expected: FAIL — `Paths` not found.

- [ ] **Step 2.3: Write minimal implementation**

`App/Paths.swift`:

```swift
import Foundation

enum Paths {
    static var appSupportDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("cc-usage-stats", isDirectory: true)
    }

    static var stateFile: URL { appSupportDir.appendingPathComponent("state.json") }
    static var configFile: URL { appSupportDir.appendingPathComponent("config.json") }

    static var claudeSettings: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
```

- [ ] **Step 2.4: Run tests**

Run: ⌘U.
Expected: PASS.

- [ ] **Step 2.5: Commit**

```bash
git add App/Paths.swift Tests/PathsTests.swift
git commit -m "feat: add Paths helper for app support and Claude settings"
```

---

## Task 3: RateLimits parsing

**Files:**
- Create: `Core/RateLimits.swift`
- Create: `Tests/RateLimitsTests.swift`
- Create: `Tests/Fixtures/statusline-full.json`
- Create: `Tests/Fixtures/statusline-five-hour-only.json`
- Create: `Tests/Fixtures/statusline-seven-day-only.json`
- Create: `Tests/Fixtures/statusline-no-rate-limits.json`
- Create: `Tests/Fixtures/statusline-malformed.json`

- [ ] **Step 3.1: Add fixture files**

`Tests/Fixtures/statusline-full.json`:

```json
{
  "session_id": "abc",
  "model": { "id": "claude-opus-4-7", "display_name": "Opus 4.7" },
  "rate_limits": {
    "five_hour": { "used_percentage": 42.7, "resets_at": 1714075200 },
    "seven_day": { "used_percentage": 18.3, "resets_at": 1714665600 }
  }
}
```

`Tests/Fixtures/statusline-five-hour-only.json`:

```json
{
  "rate_limits": {
    "five_hour": { "used_percentage": 11.0, "resets_at": 1714075200 }
  }
}
```

`Tests/Fixtures/statusline-seven-day-only.json`:

```json
{
  "rate_limits": {
    "seven_day": { "used_percentage": 5.0, "resets_at": 1714665600 }
  }
}
```

`Tests/Fixtures/statusline-no-rate-limits.json`:

```json
{ "session_id": "abc", "model": { "id": "claude-opus-4-7" } }
```

`Tests/Fixtures/statusline-malformed.json`:

```
not-json{{{
```

Add the `Tests/Fixtures` folder to the test target's "Copy Bundle Resources" build phase.

- [ ] **Step 3.2: Write failing tests**

`Tests/RateLimitsTests.swift`:

```swift
import XCTest
@testable import CCUsageStats

final class RateLimitsTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: "json")!
        return try Data(contentsOf: url)
    }

    func testParseFullPayload() throws {
        let snapshot = try RateLimitsSnapshot.parse(statuslineJSON: fixture("statusline-full"))!
        XCTAssertEqual(snapshot.fiveHour?.usedPercentage, 42.7, accuracy: 0.001)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt, 1714075200)
        XCTAssertEqual(snapshot.sevenDay?.usedPercentage, 18.3, accuracy: 0.001)
        XCTAssertEqual(snapshot.sevenDay?.resetsAt, 1714665600)
    }

    func testParseFiveHourOnly() throws {
        let snapshot = try RateLimitsSnapshot.parse(statuslineJSON: fixture("statusline-five-hour-only"))!
        XCTAssertNotNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.sevenDay)
    }

    func testParseSevenDayOnly() throws {
        let snapshot = try RateLimitsSnapshot.parse(statuslineJSON: fixture("statusline-seven-day-only"))!
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertNotNil(snapshot.sevenDay)
    }

    func testParseMissingRateLimitsReturnsNil() throws {
        let snapshot = try RateLimitsSnapshot.parse(statuslineJSON: fixture("statusline-no-rate-limits"))
        XCTAssertNil(snapshot)
    }

    func testParseMalformedThrows() throws {
        XCTAssertThrowsError(try RateLimitsSnapshot.parse(statuslineJSON: fixture("statusline-malformed")))
    }
}
```

- [ ] **Step 3.3: Run tests to verify they fail**

Run: ⌘U with `-only-testing:CCUsageStatsTests/RateLimitsTests`.
Expected: FAIL — `RateLimitsSnapshot` not found.

- [ ] **Step 3.4: Write minimal implementation**

`Core/RateLimits.swift`:

```swift
import Foundation

struct WindowSnapshot: Codable, Equatable {
    let usedPercentage: Double
    let resetsAt: Int64

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }
}

/// Just the rate_limits block — what the cache stores.
struct RateLimitsSnapshot: Codable, Equatable {
    let fiveHour: WindowSnapshot?
    let sevenDay: WindowSnapshot?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    /// Returns nil if the payload is valid JSON but lacks a `rate_limits` field.
    /// Throws if the JSON itself is malformed.
    static func parse(statuslineJSON data: Data) throws -> RateLimitsSnapshot? {
        struct Envelope: Decodable { let rate_limits: RateLimitsSnapshot? }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return env.rate_limits
    }
}
```

- [ ] **Step 3.5: Run tests**

Run: ⌘U.
Expected: PASS — all 5 tests green.

- [ ] **Step 3.6: Commit**

```bash
git add Core/RateLimits.swift Tests/RateLimitsTests.swift Tests/Fixtures
git commit -m "feat: add RateLimitsSnapshot parser for Claude Code statusline JSON"
```

---

## Task 4: CacheStore

**Files:**
- Create: `Core/CacheStore.swift`
- Create: `Tests/CacheStoreTests.swift`

`CachedState` is what's persisted in `state.json`: `RateLimitsSnapshot` plus a `capturedAt` timestamp. Merge-on-write semantics: when a fresh payload contains only `five_hour`, an existing `seven_day` field on disk is preserved.

- [ ] **Step 4.1: Write the failing tests**

`Tests/CacheStoreTests.swift`:

```swift
import XCTest
@testable import CCUsageStats

final class CacheStoreTests: XCTestCase {
    private var tmpFile: URL!

    override func setUpWithError() throws {
        tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID()).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpFile)
    }

    func testReadAbsentReturnsNil() throws {
        XCTAssertNil(try CacheStore.read(at: tmpFile))
    }

    func testReadCorruptReturnsNil() throws {
        try Data("garbage".utf8).write(to: tmpFile)
        XCTAssertNil(try CacheStore.read(at: tmpFile))
    }

    func testWriteAndReadRoundTrip() throws {
        let snapshot = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 42, resetsAt: 100),
            sevenDay: WindowSnapshot(usedPercentage: 18, resetsAt: 200)
        )
        try CacheStore.update(at: tmpFile, with: snapshot, now: 50)
        let read = try CacheStore.read(at: tmpFile)!
        XCTAssertEqual(read.capturedAt, 50)
        XCTAssertEqual(read.snapshot, snapshot)
    }

    func testMergePreservesAbsentField() throws {
        let initial = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 10, resetsAt: 100),
            sevenDay: WindowSnapshot(usedPercentage: 20, resetsAt: 200)
        )
        try CacheStore.update(at: tmpFile, with: initial, now: 50)

        let onlyFive = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 12, resetsAt: 100),
            sevenDay: nil
        )
        try CacheStore.update(at: tmpFile, with: onlyFive, now: 60)

        let read = try CacheStore.read(at: tmpFile)!
        XCTAssertEqual(read.capturedAt, 60)
        XCTAssertEqual(read.snapshot.fiveHour?.usedPercentage, 12)
        XCTAssertEqual(read.snapshot.sevenDay?.usedPercentage, 20, "seven_day must be preserved when absent from new payload")
    }

    func testWriteIsAtomic() throws {
        // Sanity: writing should not leave behind .tmp artifacts.
        let snapshot = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 1, resetsAt: 100),
            sevenDay: nil
        )
        try CacheStore.update(at: tmpFile, with: snapshot, now: 1)
        let dir = tmpFile.deletingLastPathComponent()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(tmpFile.lastPathComponent) && $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }
}
```

- [ ] **Step 4.2: Run tests to verify they fail**

Expected: FAIL — `CacheStore` and `CachedState` not found.

- [ ] **Step 4.3: Write minimal implementation**

`Core/CacheStore.swift`:

```swift
import Foundation

struct CachedState: Codable, Equatable {
    let capturedAt: Int64
    let snapshot: RateLimitsSnapshot

    enum CodingKeys: String, CodingKey {
        case capturedAt = "captured_at"
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    init(capturedAt: Int64, snapshot: RateLimitsSnapshot) {
        self.capturedAt = capturedAt
        self.snapshot = snapshot
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = try c.decode(Int64.self, forKey: .capturedAt)
        snapshot = RateLimitsSnapshot(
            fiveHour: try c.decodeIfPresent(WindowSnapshot.self, forKey: .fiveHour),
            sevenDay: try c.decodeIfPresent(WindowSnapshot.self, forKey: .sevenDay)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(capturedAt, forKey: .capturedAt)
        try c.encodeIfPresent(snapshot.fiveHour, forKey: .fiveHour)
        try c.encodeIfPresent(snapshot.sevenDay, forKey: .sevenDay)
    }
}

enum CacheStore {
    /// Returns nil for both "file absent" and "file present but unparseable".
    /// Unparseable cache is treated as absent per spec.
    static func read(at url: URL) throws -> CachedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedState.self, from: data)
    }

    /// Merges `incoming` into existing state and atomically writes.
    /// Absent fields in `incoming` (nil five_hour or nil seven_day) preserve
    /// whatever is on disk for that field.
    static func update(at url: URL, with incoming: RateLimitsSnapshot, now: Int64) throws {
        let existing = try read(at: url)?.snapshot
        let merged = RateLimitsSnapshot(
            fiveHour: incoming.fiveHour ?? existing?.fiveHour,
            sevenDay: incoming.sevenDay ?? existing?.sevenDay
        )
        let state = CachedState(capturedAt: now, snapshot: merged)

        try Paths.ensureDirectory(url.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)

        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        // Replace target atomically. _ = ignored because replaceItemAt returns the new URL.
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
```

- [ ] **Step 4.4: Run tests**

Expected: PASS.

- [ ] **Step 4.5: Commit**

```bash
git add Core/CacheStore.swift Tests/CacheStoreTests.swift
git commit -m "feat: add CacheStore with atomic write and merge-on-write"
```

---

## Task 5: AppConfig

**Files:**
- Create: `Core/AppConfig.swift`
- Create: `Tests/AppConfigTests.swift`

- [ ] **Step 5.1: Write the failing tests**

```swift
import XCTest
@testable import CCUsageStats

final class AppConfigTests: XCTestCase {
    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("config-\(UUID()).json")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testReadAbsentReturnsEmpty() throws {
        XCTAssertNil(try AppConfig.read(at: tmp).wrappedCommand)
    }

    func testReadCorruptReturnsEmpty() throws {
        try Data("garbage".utf8).write(to: tmp)
        XCTAssertNil(try AppConfig.read(at: tmp).wrappedCommand)
    }

    func testRoundTrip() throws {
        try AppConfig.write(.init(wrappedCommand: "echo hi"), to: tmp)
        XCTAssertEqual(try AppConfig.read(at: tmp).wrappedCommand, "echo hi")
    }

    func testRoundTripNullCommand() throws {
        try AppConfig.write(.init(wrappedCommand: nil), to: tmp)
        XCTAssertNil(try AppConfig.read(at: tmp).wrappedCommand)
    }
}
```

- [ ] **Step 5.2: Run tests, verify failure**

Expected: FAIL — `AppConfig` not found.

- [ ] **Step 5.3: Write implementation**

`Core/AppConfig.swift`:

```swift
import Foundation

struct AppConfig: Codable, Equatable {
    var wrappedCommand: String?

    static let empty = AppConfig(wrappedCommand: nil)

    static func read(at url: URL) throws -> AppConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return .empty
        }
        return config
    }

    static func write(_ config: AppConfig, to url: URL) throws {
        try Paths.ensureDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
```

- [ ] **Step 5.4: Run tests**

Expected: PASS.

- [ ] **Step 5.5: Commit**

```bash
git add Core/AppConfig.swift Tests/AppConfigTests.swift
git commit -m "feat: add AppConfig store for wrappedCommand"
```

---

## Task 6: WrappedCommand spawner

**Files:**
- Create: `Statusline/WrappedCommand.swift`
- Create: `Tests/WrappedCommandTests.swift`

Spawns `/bin/sh -c "<cmd>"`, pipes provided stdin, captures stdout, enforces a hard timeout, returns whatever was captured. Errors and non-zero exits do **not** throw — they are logged and produce a (possibly empty) string.

- [ ] **Step 6.1: Write the failing tests**

```swift
import XCTest
@testable import CCUsageStats

final class WrappedCommandTests: XCTestCase {
    func testCapturesStdout() throws {
        let out = WrappedCommand.run(command: "cat", stdin: Data("hello\n".utf8), timeout: 2.0)
        XCTAssertEqual(out, "hello\n")
    }

    func testNonZeroExitReturnsCapturedStdout() throws {
        let out = WrappedCommand.run(command: "printf 'partial' && exit 3", stdin: Data(), timeout: 2.0)
        XCTAssertEqual(out, "partial")
    }

    func testTimeoutReturnsWhatWasCaptured() throws {
        let out = WrappedCommand.run(
            command: "printf 'first'; sleep 5; printf 'never'",
            stdin: Data(),
            timeout: 0.5
        )
        XCTAssertEqual(out, "first")
    }

    func testEmptyCommandReturnsEmpty() throws {
        XCTAssertEqual(WrappedCommand.run(command: "", stdin: Data(), timeout: 2.0), "")
    }
}
```

- [ ] **Step 6.2: Run tests, verify failure**

Expected: FAIL — `WrappedCommand` undefined.

- [ ] **Step 6.3: Write implementation**

`Statusline/WrappedCommand.swift`:

```swift
import Foundation

enum WrappedCommand {
    /// Runs `/bin/sh -c command`. Always returns the captured stdout (possibly empty).
    /// Never throws; never propagates errors.
    static func run(command: String, stdin: Data, timeout: TimeInterval) -> String {
        guard !command.isEmpty else { return "" }

        let process = Process()
        process.launchPath = "/bin/sh"
        process.arguments = ["-c", command]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe() // discard

        do { try process.run() } catch {
            return ""
        }

        // Feed stdin then close.
        try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
        try? stdinPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        var captured = Data()
        let readHandle = stdoutPipe.fileHandleForReading

        while process.isRunning && Date() < deadline {
            let chunk = readHandle.availableData
            if !chunk.isEmpty { captured.append(chunk) }
            else { Thread.sleep(forTimeInterval: 0.01) }
        }

        if process.isRunning {
            process.terminate()
            // Brief grace period.
            let grace = Date().addingTimeInterval(0.2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        // Drain anything remaining.
        let rest = readHandle.readDataToEndOfFile()
        if !rest.isEmpty { captured.append(rest) }

        return String(data: captured, encoding: .utf8) ?? ""
    }
}
```

- [ ] **Step 6.4: Run tests**

Expected: PASS — all four tests green. The timeout test must reliably hit 0.5s; if flaky, bump to 1.0s.

- [ ] **Step 6.5: Commit**

```bash
git add Statusline/WrappedCommand.swift Tests/WrappedCommandTests.swift
git commit -m "feat: add WrappedCommand spawner with timeout and error swallowing"
```

---

## Task 7: StatuslineMode end-to-end

**Files:**
- Create: `Statusline/StatuslineMode.swift`
- Create: `Tests/StatuslineModeTests.swift`

The single function `StatuslineMode.run(stdin:cacheURL:configURL:now:)` is what `argv[1] == "statusline"` dispatches to. Returns the string to print to stdout. The CLI mode wires it up with real `FileHandle.standardInput` and `print(...)`.

- [ ] **Step 7.1: Write the failing tests**

```swift
import XCTest
@testable import CCUsageStats

final class StatuslineModeTests: XCTestCase {
    private var stateURL: URL!
    private var configURL: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stateURL = dir.appendingPathComponent("state.json")
        configURL = dir.appendingPathComponent("config.json")
    }

    func testWritesCacheAndReturnsInnerStdout() throws {
        try AppConfig.write(.init(wrappedCommand: "printf 'inner-output'"), to: configURL)
        let stdin = try Data(contentsOf: Bundle(for: type(of: self)).url(forResource: "statusline-full", withExtension: "json")!)

        let out = StatuslineMode.run(stdin: stdin, cacheURL: stateURL, configURL: configURL, now: 1000)

        XCTAssertEqual(out, "inner-output")
        let cached = try CacheStore.read(at: stateURL)!
        XCTAssertEqual(cached.capturedAt, 1000)
        XCTAssertEqual(cached.snapshot.fiveHour?.usedPercentage, 42.7, accuracy: 0.001)
    }

    func testMissingRateLimitsLeavesCacheUntouchedButStillCallsInner() throws {
        // Pre-existing cache.
        let pre = RateLimitsSnapshot(
            fiveHour: WindowSnapshot(usedPercentage: 5, resetsAt: 100),
            sevenDay: nil
        )
        try CacheStore.update(at: stateURL, with: pre, now: 500)

        try AppConfig.write(.init(wrappedCommand: "printf 'still-runs'"), to: configURL)

        let stdin = try Data(contentsOf: Bundle(for: type(of: self)).url(forResource: "statusline-no-rate-limits", withExtension: "json")!)
        let out = StatuslineMode.run(stdin: stdin, cacheURL: stateURL, configURL: configURL, now: 9999)

        XCTAssertEqual(out, "still-runs")
        let cached = try CacheStore.read(at: stateURL)!
        XCTAssertEqual(cached.capturedAt, 500, "captured_at must NOT advance when rate_limits absent")
    }

    func testMalformedStdinReturnsInnerOutputAndDoesNotTouchCache() throws {
        try AppConfig.write(.init(wrappedCommand: "printf 'survived'"), to: configURL)
        let stdin = Data("not json".utf8)

        let out = StatuslineMode.run(stdin: stdin, cacheURL: stateURL, configURL: configURL, now: 1)
        XCTAssertEqual(out, "survived")
        XCTAssertNil(try CacheStore.read(at: stateURL))
    }

    func testNoWrappedCommandReturnsEmpty() throws {
        try AppConfig.write(.empty, to: configURL)
        let stdin = try Data(contentsOf: Bundle(for: type(of: self)).url(forResource: "statusline-full", withExtension: "json")!)
        let out = StatuslineMode.run(stdin: stdin, cacheURL: stateURL, configURL: configURL, now: 1)
        XCTAssertEqual(out, "")
    }
}
```

- [ ] **Step 7.2: Run tests, verify failure**

Expected: FAIL — `StatuslineMode` undefined.

- [ ] **Step 7.3: Write implementation**

`Statusline/StatuslineMode.swift`:

```swift
import Foundation
import os

enum StatuslineMode {
    private static let log = Logger(subsystem: "dev.dv.ccusagestats", category: "statusline")

    /// Pure-ish entry point: takes raw stdin bytes, file URLs, and a clock.
    /// Returns the string to forward to Claude Code on stdout.
    /// Must NOT throw — Claude Code's UI must keep working.
    static func run(stdin: Data, cacheURL: URL, configURL: URL, now: Int64) -> String {
        // 1. Update cache from rate_limits if present and parseable.
        if let snapshot = (try? RateLimitsSnapshot.parse(statuslineJSON: stdin)) ?? nil {
            do {
                try CacheStore.update(at: cacheURL, with: snapshot, now: now)
            } catch {
                log.error("CacheStore.update failed: \(String(describing: error), privacy: .public)")
            }
        }
        // (If parse threw or returned nil, leave cache untouched.)

        // 2. Run wrapped inner command (if any) with the same stdin.
        let config = (try? AppConfig.read(at: configURL)) ?? .empty
        guard let cmd = config.wrappedCommand, !cmd.isEmpty else { return "" }
        return WrappedCommand.run(command: cmd, stdin: stdin, timeout: 4.0)
    }

    /// CLI entry — wires real stdin / stdout.
    static func runFromCLI() -> Never {
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        let now = Int64(Date().timeIntervalSince1970)
        let out = run(stdin: stdin, cacheURL: Paths.stateFile, configURL: Paths.configFile, now: now)
        if let data = out.data(using: .utf8) {
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
        exit(0)
    }
}
```

- [ ] **Step 7.4: Run tests**

Expected: PASS.

- [ ] **Step 7.5: Commit**

```bash
git add Statusline/StatuslineMode.swift Tests/StatuslineModeTests.swift
git commit -m "feat: add StatuslineMode that updates cache and forwards to wrapped command"
```

---

## Task 8: Mode dispatch from app entry

**Files:**
- Modify: `App/CCUsageStatsApp.swift`

- [ ] **Step 8.1: Update `@main` to branch on argv**

Replace `App/CCUsageStatsApp.swift` with:

```swift
import SwiftUI

@main
struct CCUsageStatsApp: App {
    init() {
        let args = CommandLine.arguments
        if args.count >= 2 && args[1] == "statusline" {
            StatuslineMode.runFromCLI() // exits.
        }
    }

    var body: some Scene {
        MenuBarExtra("cc-usage-stats", systemImage: "gauge.with.dots.needle.33percent") {
            Text("placeholder — ui in later tasks")
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}
```

- [ ] **Step 8.2: Manual smoke test for statusline mode**

Build the app; locate the `cc-usage-stats` binary inside the bundle:

```bash
xcodebuild -scheme CCUsageStats -configuration Debug -derivedDataPath build > /dev/null
BIN="$(find build/Build/Products -name CCUsageStats -type f | head -1)"
echo '{"rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":9999999999}}}' | "$BIN" statusline
cat "$HOME/Library/Application Support/cc-usage-stats/state.json"
```

Expected: stdout from binary is empty (no wrapped command yet); `state.json` contains the snapshot with `captured_at` set to current epoch.

- [ ] **Step 8.3: Commit**

```bash
git add App/CCUsageStatsApp.swift
git commit -m "feat: dispatch to StatuslineMode when invoked with 'statusline' arg"
```

---

## Task 9: DisplayState

**Files:**
- Create: `Core/DisplayState.swift`
- Create: `Tests/DisplayStateTests.swift`

A pure function that computes what the menubar should show. Inputs: current epoch, optional `CachedState`. Outputs: text label, color tier, freshness.

- [ ] **Step 9.1: Write the failing tests**

```swift
import XCTest
@testable import CCUsageStats

final class DisplayStateTests: XCTestCase {
    func testNoCacheGivesPlaceholder() {
        let s = DisplayState.compute(now: 100, cached: nil)
        XCTAssertEqual(s.menuBarText, "—")
        XCTAssertEqual(s.tier, .neutral)
        XCTAssertFalse(s.isStale)
        XCTAssertFalse(s.hasFiveHourData)
    }

    func testFreshLowUsage() {
        let cached = CachedState(
            capturedAt: 100,
            snapshot: .init(fiveHour: .init(usedPercentage: 12.4, resetsAt: 1000), sevenDay: nil)
        )
        let s = DisplayState.compute(now: 200, cached: cached)
        XCTAssertEqual(s.menuBarText, "12%")
        XCTAssertEqual(s.tier, .neutral)
        XCTAssertFalse(s.isStale)
    }

    func testYellowTier() {
        let cached = CachedState(
            capturedAt: 100,
            snapshot: .init(fiveHour: .init(usedPercentage: 65, resetsAt: 1000), sevenDay: nil)
        )
        XCTAssertEqual(DisplayState.compute(now: 100, cached: cached).tier, .warning)
    }

    func testRedTier() {
        let cached = CachedState(
            capturedAt: 100,
            snapshot: .init(fiveHour: .init(usedPercentage: 90, resetsAt: 1000), sevenDay: nil)
        )
        XCTAssertEqual(DisplayState.compute(now: 100, cached: cached).tier, .danger)
    }

    func testStaleAfter30Min() {
        let cached = CachedState(
            capturedAt: 0,
            snapshot: .init(fiveHour: .init(usedPercentage: 10, resetsAt: 9999), sevenDay: nil)
        )
        let s = DisplayState.compute(now: 30 * 60 + 1, cached: cached)
        XCTAssertTrue(s.isStale)
    }

    func testNoFiveHourFallsBackToPlaceholder() {
        let cached = CachedState(
            capturedAt: 100,
            snapshot: .init(fiveHour: nil, sevenDay: .init(usedPercentage: 30, resetsAt: 1000))
        )
        let s = DisplayState.compute(now: 100, cached: cached)
        XCTAssertEqual(s.menuBarText, "—")
        XCTAssertFalse(s.hasFiveHourData)
    }
}
```

- [ ] **Step 9.2: Run tests, verify failure**

- [ ] **Step 9.3: Write implementation**

`Core/DisplayState.swift`:

```swift
import Foundation

struct DisplayState: Equatable {
    enum Tier { case neutral, warning, danger }

    let menuBarText: String
    let tier: Tier
    let isStale: Bool
    let hasFiveHourData: Bool

    static let staleThresholdSeconds: Int64 = 30 * 60

    static func compute(now: Int64, cached: CachedState?) -> DisplayState {
        guard let cached, let five = cached.snapshot.fiveHour else {
            return .init(menuBarText: "—", tier: .neutral, isStale: false, hasFiveHourData: false)
        }
        let pct = Int(five.usedPercentage.rounded())
        let tier: Tier
        switch pct {
        case ..<50:  tier = .neutral
        case 50..<80: tier = .warning
        default:      tier = .danger
        }
        let stale = (now - cached.capturedAt) > staleThresholdSeconds
        return .init(menuBarText: "\(pct)%", tier: tier, isStale: stale, hasFiveHourData: true)
    }
}
```

- [ ] **Step 9.4: Run tests**

Expected: PASS.

- [ ] **Step 9.5: Commit**

```bash
git add Core/DisplayState.swift Tests/DisplayStateTests.swift
git commit -m "feat: add DisplayState pure function for menubar rendering"
```

---

## Task 10: CacheWatcher

**Files:**
- Create: `Tray/CacheWatcher.swift`
- Create: `Tests/CacheWatcherTests.swift`

Wraps `DispatchSource.makeFileSystemObjectSource` to publish `.write` / `.rename` events. Re-opens the file descriptor on `.delete` (because atomic rename replaces the inode). Surfaces a single `onChange: () -> Void` callback.

- [ ] **Step 10.1: Write the failing test**

```swift
import XCTest
@testable import CCUsageStats

final class CacheWatcherTests: XCTestCase {
    func testCallbackFiresAfterAtomicWrite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID()).json")
        try Data("{}".utf8).write(to: url)

        let exp = expectation(description: "callback fires")
        exp.expectedFulfillmentCount = 1
        exp.assertForOverFulfill = false

        let watcher = CacheWatcher(url: url) { exp.fulfill() }
        watcher.start()

        // Wait briefly so the watcher is fully attached before we mutate.
        Thread.sleep(forTimeInterval: 0.1)

        let snapshot = RateLimitsSnapshot(fiveHour: .init(usedPercentage: 5, resetsAt: 100), sevenDay: nil)
        try CacheStore.update(at: url, with: snapshot, now: 1)

        wait(for: [exp], timeout: 2.0)
        watcher.stop()
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 10.2: Run, verify failure**

- [ ] **Step 10.3: Write implementation**

`Tray/CacheWatcher.swift`:

```swift
import Foundation

final class CacheWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        attach()
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
    }

    private func attach() {
        // Ensure file exists so we can open it. If absent, create empty marker;
        // the cache writer will replace it atomically.
        try? Paths.ensureDirectory(url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.onChange() }
            // On rename/delete, atomic rename replaced the inode. Re-attach.
            let mask = src.data
            if mask.contains(.rename) || mask.contains(.delete) {
                self.stop()
                // Small retry — the new file may not exist yet for a microsecond.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.attach() }
            }
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        src.resume()
        source = src
    }
}
```

- [ ] **Step 10.4: Run tests**

Expected: PASS within 2s. If flaky, lengthen `Thread.sleep` to 0.2s.

- [ ] **Step 10.5: Commit**

```bash
git add Tray/CacheWatcher.swift Tests/CacheWatcherTests.swift
git commit -m "feat: add CacheWatcher that re-attaches after atomic rename"
```

---

## Task 11: MenuViewModel

**Files:**
- Create: `Tray/MenuViewModel.swift`

No new tests — the component is composed of already-tested pieces (`CacheStore`, `DisplayState`, `CacheWatcher`). It exposes published state for SwiftUI.

- [ ] **Step 11.1: Write implementation**

```swift
import Foundation
import Combine

@MainActor
final class MenuViewModel: ObservableObject {
    @Published private(set) var displayState: DisplayState = .init(
        menuBarText: "—", tier: .neutral, isStale: false, hasFiveHourData: false
    )
    @Published private(set) var cached: CachedState?

    private var watcher: CacheWatcher?
    private var clockTimer: Timer?

    func start() {
        reload()
        watcher = CacheWatcher(url: Paths.stateFile) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        watcher?.start()

        // Tick once a minute so freshness/countdowns update without a write.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recomputeFromCachedOnly() }
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        clockTimer?.invalidate()
        clockTimer = nil
    }

    private func reload() {
        cached = (try? CacheStore.read(at: Paths.stateFile)) ?? nil
        recomputeFromCachedOnly()
    }

    private func recomputeFromCachedOnly() {
        let now = Int64(Date().timeIntervalSince1970)
        displayState = DisplayState.compute(now: now, cached: cached)
    }
}
```

- [ ] **Step 11.2: Manual integration check**

(No new test file; covered in Task 12 smoke.)

- [ ] **Step 11.3: Commit**

```bash
git add Tray/MenuViewModel.swift
git commit -m "feat: add MenuViewModel composing watcher, store, and display state"
```

---

## Task 12: MenuBarContent UI

**Files:**
- Create: `Tray/MenuBarContent.swift`
- Create: `Tray/RelativeTime.swift` (small helper — pure function)
- Create: `Tests/RelativeTimeTests.swift`
- Modify: `App/CCUsageStatsApp.swift`

- [ ] **Step 12.1: Write the failing test for RelativeTime**

```swift
import XCTest
@testable import CCUsageStats

final class RelativeTimeTests: XCTestCase {
    func testSeconds()  { XCTAssertEqual(RelativeTime.format(seconds: 12), "12s") }
    func testMinutes()  { XCTAssertEqual(RelativeTime.format(seconds: 90), "1m") }
    func testHours()    { XCTAssertEqual(RelativeTime.format(seconds: 3600 * 2 + 60 * 14), "2h 14m") }
    func testDays()     { XCTAssertEqual(RelativeTime.format(seconds: 86400 * 5 + 3600 * 6), "5d 6h") }
    func testZero()     { XCTAssertEqual(RelativeTime.format(seconds: 0), "0s") }
    func testNegativeClampsToZero() { XCTAssertEqual(RelativeTime.format(seconds: -10), "0s") }
}
```

- [ ] **Step 12.2: Verify failure, write `RelativeTime`**

`Tray/RelativeTime.swift`:

```swift
import Foundation

enum RelativeTime {
    static func format(seconds raw: Int64) -> String {
        let s = max(0, raw)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        let remM = m % 60
        if h < 24 { return "\(h)h \(remM)m" }
        let d = h / 24
        let remH = h % 24
        return "\(d)d \(remH)h"
    }
}
```

Run tests → PASS.

- [ ] **Step 12.3: Build dropdown UI**

`Tray/MenuBarContent.swift`:

```swift
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var vm: MenuViewModel
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: glyph(for: vm.displayState.tier))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color(for: vm.displayState))
            Text(vm.displayState.menuBarText)
                .opacity(vm.displayState.isStale ? 0.5 : 1.0)
                .monospacedDigit()
        }
    }

    private func glyph(for tier: DisplayState.Tier) -> String {
        switch tier {
        case .neutral: return "gauge.with.dots.needle.33percent"
        case .warning: return "gauge.with.dots.needle.50percent"
        case .danger:  return "gauge.with.dots.needle.67percent"
        }
    }

    private func color(for s: DisplayState) -> Color {
        if s.isStale { return .secondary }
        switch s.tier {
        case .neutral: return .primary
        case .warning: return .yellow
        case .danger:  return .red
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
            Text("No data captured yet — install statusline integration below.")
                .foregroundStyle(.secondary)
        }

        Divider()
        // Settings rows wired in Task 13.
        Text("Settings (coming next task)").foregroundStyle(.secondary)

        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var now: Int64 { Int64(Date().timeIntervalSince1970) }
}

private struct WindowRow: View {
    let title: String
    let window: WindowSnapshot?
    let now: Int64

    var body: some View {
        if let w = window {
            let pct = Int(w.usedPercentage.rounded())
            let resetIn = w.resetsAt - now
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title): \(pct)%")
                Text("resets in \(RelativeTime.format(seconds: resetIn))")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        } else {
            Text("\(title): not yet observed").foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 12.4: Wire into the App scene**

Replace the `MenuBarExtra` body in `App/CCUsageStatsApp.swift`:

```swift
@StateObject private var vm = MenuViewModel()

var body: some Scene {
    MenuBarExtra {
        MenuBarDropdown(vm: vm)
    } label: {
        MenuBarLabel(vm: vm)
    }
    .menuBarExtraStyle(.menu)
    .onChange(of: scenePhase) { _ in } // placeholder if needed later
}
```

Add at top of `init()` (after the statusline branch):

```swift
// no-op; vm.start() is called in onAppear via MenuBarLabel.task
```

Actually call `vm.start()` from `MenuBarLabel`:

```swift
.task { await MainActor.run { vm.start() } }
```

(Adjust as needed — the goal is `vm.start()` runs once on app launch.)

- [ ] **Step 12.5: Manual smoke test**

Build & run. With no `state.json`: dropdown reads "No data captured yet…", menubar shows `—`.

Then in another terminal:

```bash
mkdir -p "$HOME/Library/Application Support/cc-usage-stats"
cat > "$HOME/Library/Application Support/cc-usage-stats/state.json.tmp" <<'EOF'
{"captured_at": SECONDS_NOW, "five_hour": {"used_percentage": 65.0, "resets_at": SECONDS_PLUS_2H}, "seven_day": {"used_percentage": 18.0, "resets_at": SECONDS_PLUS_7D}}
EOF
mv "$HOME/Library/Application Support/cc-usage-stats/state.json.tmp" "$HOME/Library/Application Support/cc-usage-stats/state.json"
```

Replace `SECONDS_NOW` etc. with actual epochs (e.g. `date +%s`, `$(($(date +%s) + 7200))`).

Expected: menubar updates within ~1s to `65%` in yellow; dropdown shows both rows with countdowns.

- [ ] **Step 12.6: Commit**

```bash
git add Tray App
git commit -m "feat: add menubar dropdown UI with live data and countdowns"
```

---

## Task 13: Installer for `~/.claude/settings.json`

**Files:**
- Create: `Tray/Installer.swift`
- Create: `Tests/InstallerTests.swift`

The installer is the trickiest piece. Test it thoroughly.

- [ ] **Step 13.1: Write the failing tests**

```swift
import XCTest
@testable import CCUsageStats

final class InstallerTests: XCTestCase {
    private var dir: URL!
    private var settings: URL!
    private var config: URL!
    private let stubBinary = "/usr/local/bin/cc-usage-stats"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings = dir.appendingPathComponent("settings.json")
        config = dir.appendingPathComponent("config.json")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testInstallIntoEmptyFile() throws {
        try Data("{}".utf8).write(to: settings)
        try Installer.install(settingsURL: settings, configURL: config, binaryPath: stubBinary)

        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        let sl = parsed["statusLine"] as! [String: Any]
        XCTAssertEqual(sl["type"] as? String, "command")
        XCTAssertEqual(sl["command"] as? String, "\(stubBinary) statusline")

        let conf = try AppConfig.read(at: config)
        XCTAssertNil(conf.wrappedCommand, "no prior statusLine → wrappedCommand is nil")

        // Backup created.
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(entries.contains { $0.hasPrefix("settings.json.bak.") })
    }

    func testInstallPreservesExistingStatusLine() throws {
        let original: [String: Any] = [
            "statusLine": ["type": "command", "command": "/usr/local/bin/old-statusline"],
            "env": ["FOO": "BAR"]
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)

        try Installer.install(settingsURL: settings, configURL: config, binaryPath: stubBinary)

        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertEqual((parsed["statusLine"] as! [String: Any])["command"] as? String, "\(stubBinary) statusline")
        XCTAssertEqual((parsed["env"] as! [String: Any])["FOO"] as? String, "BAR")

        let conf = try AppConfig.read(at: config)
        XCTAssertEqual(conf.wrappedCommand, "/usr/local/bin/old-statusline")
    }

    func testInstallIsIdempotent() throws {
        try Data("{}".utf8).write(to: settings)
        try Installer.install(settingsURL: settings, configURL: config, binaryPath: stubBinary)
        try Installer.install(settingsURL: settings, configURL: config, binaryPath: stubBinary)

        // wrappedCommand must remain nil — second install must NOT capture our own command as the inner one.
        let conf = try AppConfig.read(at: config)
        XCTAssertNil(conf.wrappedCommand)
    }

    func testUninstallRestoresPreviousCommand() throws {
        let original: [String: Any] = [
            "statusLine": ["type": "command", "command": "/usr/local/bin/old-statusline"]
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)

        try Installer.install(settingsURL: settings, configURL: config, binaryPath: stubBinary)
        try Installer.uninstall(settingsURL: settings, configURL: config, binaryPath: stubBinary)

        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertEqual((parsed["statusLine"] as! [String: Any])["command"] as? String, "/usr/local/bin/old-statusline")
    }

    func testUninstallRemovesStatusLineWhenNoneOriginally() throws {
        try Data("{}".utf8).write(to: settings)

        try Installer.install(settingsURL: settings, configURL: config, binaryPath: stubBinary)
        try Installer.uninstall(settingsURL: settings, configURL: config, binaryPath: stubBinary)

        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertNil(parsed["statusLine"])
    }

    func testInstallAbortsOnMalformedJSON() throws {
        try Data("{not json".utf8).write(to: settings)
        XCTAssertThrowsError(try Installer.install(settingsURL: settings, configURL: config, binaryPath: stubBinary))
    }

    func testCurrentStateDetectsInstalled() throws {
        try Data("{}".utf8).write(to: settings)
        try Installer.install(settingsURL: settings, configURL: config, binaryPath: stubBinary)
        XCTAssertEqual(try Installer.currentState(settingsURL: settings, binaryPath: stubBinary), .installed)
    }

    func testCurrentStateDetectsNotInstalled() throws {
        try Data("{}".utf8).write(to: settings)
        XCTAssertEqual(try Installer.currentState(settingsURL: settings, binaryPath: stubBinary), .notInstalled)
    }

    func testInstallFollowsSymlink() throws {
        // Real file lives elsewhere; `settings` is a symlink to it.
        let realFile = dir.appendingPathComponent("real-settings.json")
        try Data("{}".utf8).write(to: realFile)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: realFile)

        try Installer.install(settingsURL: settings, configURL: config, binaryPath: stubBinary)

        // The symlink itself should still be a symlink — we should have edited the target, not replaced the link.
        let attrs = try FileManager.default.attributesOfItem(atPath: settings.path)
        // attributesOfItem follows symlinks, so check via lstat:
        var st = stat()
        XCTAssertEqual(lstat(settings.path, &st), 0)
        XCTAssertTrue((st.st_mode & S_IFMT) == S_IFLNK, "settings.json must remain a symlink after install")
        _ = attrs

        // Real file got the new content.
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: realFile)) as! [String: Any]
        XCTAssertNotNil(parsed["statusLine"])
    }
}
```

- [ ] **Step 13.2: Run, verify failures**

- [ ] **Step 13.3: Write implementation**

`Tray/Installer.swift`:

```swift
import Foundation

enum Installer {
    enum State: Equatable { case installed, notInstalled }
    enum InstallError: Error { case malformedSettings, ioError(Error) }

    private static func ourCommand(for binaryPath: String) -> String {
        "\(binaryPath) statusline"
    }

    static func currentState(settingsURL: URL, binaryPath: String) throws -> State {
        let dict = try readDictionary(settingsURL)
        guard let sl = dict["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String else { return .notInstalled }
        return cmd == ourCommand(for: binaryPath) ? .installed : .notInstalled
    }

    /// Wrap the existing statusLine.command (if any) and replace with ours.
    /// Idempotent: if already installed, does NOT overwrite wrappedCommand.
    static func install(settingsURL: URL, configURL: URL, binaryPath: String) throws {
        var dict = try readDictionary(settingsURL)
        let target = ourCommand(for: binaryPath)

        let alreadyInstalled: Bool = {
            guard let sl = dict["statusLine"] as? [String: Any],
                  let cmd = sl["command"] as? String else { return false }
            return cmd == target
        }()

        if !alreadyInstalled {
            // Capture previous command.
            let previous = (dict["statusLine"] as? [String: Any])?["command"] as? String
            try AppConfig.write(.init(wrappedCommand: previous), to: configURL)
        }
        // else: leave config.json untouched.

        try createBackup(settingsURL)

        dict["statusLine"] = [
            "type": "command",
            "command": target
        ]
        try writeDictionary(dict, to: settingsURL)
    }

    /// Restore previously-wrapped command (if any) from config.json.
    static func uninstall(settingsURL: URL, configURL: URL, binaryPath: String) throws {
        var dict = try readDictionary(settingsURL)
        let conf = try AppConfig.read(at: configURL)

        try createBackup(settingsURL)

        if let wrapped = conf.wrappedCommand, !wrapped.isEmpty {
            dict["statusLine"] = ["type": "command", "command": wrapped]
        } else {
            dict.removeValue(forKey: "statusLine")
        }
        try writeDictionary(dict, to: settingsURL)
    }

    // MARK: - helpers

    /// Resolve POSIX symlinks (NOT Finder aliases) so we edit the actual target file.
    private static func resolved(_ url: URL) -> URL {
        URL(fileURLWithPath: url.resolvingSymlinksInPath().path)
    }

    private static func readDictionary(_ url: URL) throws -> [String: Any] {
        let r = resolved(url)
        guard let data = try? Data(contentsOf: r) else { return [:] }
        if data.isEmpty { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            throw InstallError.malformedSettings
        }
        return dict
    }

    private static func writeDictionary(_ dict: [String: Any], to url: URL) throws {
        let r = resolved(url)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        let tmp = r.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(r, withItemAt: tmp)
    }

    private static func createBackup(_ url: URL) throws {
        let r = resolved(url)
        guard FileManager.default.fileExists(atPath: r.path) else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let ts = fmt.string(from: Date())
        let backup = r.appendingPathExtension("bak.\(ts)")
        try FileManager.default.copyItem(at: r, to: backup)
    }
}
```

- [ ] **Step 13.4: Run tests**

Expected: PASS — all 8 tests.

- [ ] **Step 13.5: Commit**

```bash
git add Tray/Installer.swift Tests/InstallerTests.swift
git commit -m "feat: add Installer for ~/.claude/settings.json with backup and idempotency"
```

---

## Task 14: LaunchAtLoginService

**Files:**
- Create: `Tray/LaunchAtLoginService.swift`

`SMAppService` doesn't lend itself to unit testing — it touches global state. We provide a thin wrapper and verify manually.

- [ ] **Step 14.1: Write implementation**

```swift
import ServiceManagement

enum LaunchAtLoginService {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
```

- [ ] **Step 14.2: Manual smoke**

(Tested as part of Task 15's UI integration.)

- [ ] **Step 14.3: Commit**

```bash
git add Tray/LaunchAtLoginService.swift
git commit -m "feat: add LaunchAtLoginService wrapper around SMAppService"
```

---

## Task 15: Wire install / launch-at-login into the dropdown

**Files:**
- Modify: `Tray/MenuBarContent.swift`
- Modify: `Tray/MenuViewModel.swift`

- [ ] **Step 15.1: Extend `MenuViewModel` with action methods**

Add to `MenuViewModel`:

```swift
@Published var installState: Installer.State = .notInstalled
@Published var launchAtLogin: Bool = LaunchAtLoginService.isEnabled
@Published var lastError: String?

private var binaryPath: String {
    Bundle.main.executableURL?.path ?? "cc-usage-stats"
}

func refreshSettingsState() {
    installState = (try? Installer.currentState(settingsURL: Paths.claudeSettings, binaryPath: binaryPath)) ?? .notInstalled
    launchAtLogin = LaunchAtLoginService.isEnabled
}

func install() {
    do {
        try Installer.install(settingsURL: Paths.claudeSettings, configURL: Paths.configFile, binaryPath: binaryPath)
        refreshSettingsState()
    } catch {
        lastError = "Install failed: \(error)"
    }
}

func uninstall() {
    do {
        try Installer.uninstall(settingsURL: Paths.claudeSettings, configURL: Paths.configFile, binaryPath: binaryPath)
        refreshSettingsState()
    } catch {
        lastError = "Uninstall failed: \(error)"
    }
}

func toggleLaunchAtLogin() {
    let newValue = !launchAtLogin
    do { try LaunchAtLoginService.setEnabled(newValue); launchAtLogin = newValue }
    catch { lastError = "Launch-at-login toggle failed: \(error)" }
}
```

Call `refreshSettingsState()` from `start()` and on each menu open (handled in the view).

- [ ] **Step 15.2: Add menu rows with confirmation dialog**

The spec requires a confirmation dialog with a diff preview before mutating
`settings.json`. We use `NSAlert` with the diff in its `informativeText`.

Add to `MenuViewModel`:

```swift
/// Builds a human-readable preview of the change Install would make.
/// Returns (currentCommand, plannedCommand). Either may be nil.
func installPreview() -> (current: String?, planned: String) {
    let current = (try? Installer.installedBinaryPath(settingsURL: Paths.claudeSettings))
        .flatMap { _ in
            // Read raw command, not just binary path.
            (try? Data(contentsOf: Paths.claudeSettings))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["statusLine"] as? [String: Any] }
                .flatMap { $0["command"] as? String }
        }
    return (current, "\(binaryPath) statusline")
}
```

In `MenuBarDropdown`, replace the placeholder "Settings" line with:

```swift
Toggle("Launch at Login", isOn: Binding(
    get: { vm.launchAtLogin },
    set: { _ in vm.toggleLaunchAtLogin() }
))

if vm.installState == .installed {
    Button("Uninstall Statusline Integration…") { confirmAndUninstall() }
} else {
    Button("Install Statusline Integration…") { confirmAndInstall() }
}

if let err = vm.lastError {
    Text(err).foregroundStyle(.red).font(.caption)
}
```

Add helper functions in `MenuBarDropdown`:

```swift
private func confirmAndInstall() {
    let preview = vm.installPreview()
    let alert = NSAlert()
    alert.messageText = "Install Statusline Integration"
    alert.informativeText = """
    This will modify ~/.claude/settings.json. A timestamped backup will be created.

    Current statusLine.command:
      \(preview.current ?? "(none)")

    New statusLine.command:
      \(preview.planned)

    \(preview.current.map { _ in "Your previous command will be wrapped and continue to run." } ?? "")
    """
    alert.addButton(withTitle: "Install")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn { vm.install() }
}

private func confirmAndUninstall() {
    let alert = NSAlert()
    alert.messageText = "Uninstall Statusline Integration"
    alert.informativeText = "This will restore your previous statusLine command (or remove it entirely if there was none). A backup will be created."
    alert.addButton(withTitle: "Uninstall")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn { vm.uninstall() }
}
```

Refresh on appear:

```swift
.onAppear { vm.refreshSettingsState() }
```

- [ ] **Step 15.3: Manual smoke**

1. Run the app from Xcode.
2. Click menubar → click **Install Statusline Integration…**.
3. In a terminal: `cat ~/.claude/settings.json` — verify `statusLine.command` points at the running app's binary path inside `DerivedData`.
4. Verify `~/.claude/settings.json.bak.<timestamp>` exists.
5. Verify `~/Library/Application Support/cc-usage-stats/config.json` contains the previous command (your caveman script).
6. Run an actual Claude Code session in another terminal — confirm the caveman statusline still renders normally (proves wrap+forward works) and that the menubar `—` becomes a real percentage within seconds.
7. Click menubar again → menu now shows **Uninstall Statusline Integration…**. Click it. Verify `settings.json` is restored to the original caveman command.

- [ ] **Step 15.4: Commit**

```bash
git add Tray
git commit -m "feat: wire install/uninstall and launch-at-login into dropdown"
```

---

## Task 16: Build / install scripts

**Files:**
- Create: `scripts/build.sh`
- Create: `scripts/install-dev.sh`

- [ ] **Step 16.1: Write `scripts/build.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild \
  -scheme CCUsageStats \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  build

mkdir -p dist
APP="$(find build/Build/Products/Release -maxdepth 1 -name '*.app' -print -quit)"
rm -rf "dist/CCUsageStats.app"
cp -R "$APP" "dist/"
echo "Built: dist/CCUsageStats.app"
```

`chmod +x scripts/build.sh`.

- [ ] **Step 16.2: Write `scripts/install-dev.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh

DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/CCUsageStats.app"
cp -R dist/CCUsageStats.app "$DEST/"

# Restart the app.
killall CCUsageStats 2>/dev/null || true
open "$DEST/CCUsageStats.app"
echo "Installed to $DEST/CCUsageStats.app and (re)started."
```

`chmod +x scripts/install-dev.sh`.

- [ ] **Step 16.3: Run end-to-end**

```bash
./scripts/install-dev.sh
```

Expected: app rebuilds, copies to `~/Applications/CCUsageStats.app`, the menubar icon appears.

If you'd previously installed the integration with the DerivedData binary path, click **Install Statusline Integration…** again — it will detect the binary moved and rewrite `settings.json` to the new path. (See spec edge case "App `.app` bundle moved after install".)

- [ ] **Step 16.4: Commit**

```bash
git add scripts
git commit -m "chore: add build and install-dev scripts"
```

---

## Task 17: Path-mismatch warning in dropdown

**Files:**
- Modify: `Tray/Installer.swift` (add `installedBinaryPath` accessor)
- Modify: `Tray/MenuViewModel.swift`
- Modify: `Tray/MenuBarContent.swift`

- [ ] **Step 17.1: Add `installedBinaryPath` to Installer**

```swift
/// Returns the binary path currently configured in settings.json's statusLine.command,
/// stripped of trailing " statusline". Nil if no statusLine.
static func installedBinaryPath(settingsURL: URL) throws -> String? {
    let dict = try readDictionary(settingsURL)
    guard let sl = dict["statusLine"] as? [String: Any],
          let cmd = sl["command"] as? String else { return nil }
    let suffix = " statusline"
    guard cmd.hasSuffix(suffix) else { return nil }
    return String(cmd.dropLast(suffix.count))
}
```

- [ ] **Step 17.2: Surface mismatch in viewmodel + UI**

In `MenuViewModel.refreshSettingsState`:

```swift
let installed = try? Installer.installedBinaryPath(settingsURL: Paths.claudeSettings)
self.pathMismatch = (installed != nil) && (installed != binaryPath)
```

Add `@Published var pathMismatch = false`.

In dropdown:

```swift
if vm.pathMismatch {
    Text("⚠︎ Configured at a different path. Click Install to update.")
        .foregroundStyle(.orange).font(.caption)
}
```

- [ ] **Step 17.3: Manual smoke**

1. Install from app at path A.
2. Move/rename the `.app` bundle.
3. Re-launch from new path B.
4. Open dropdown → mismatch warning appears.
5. Click Install → warning disappears; `settings.json` updated.

- [ ] **Step 17.4: Commit**

```bash
git add Tray
git commit -m "feat: warn when configured statusline path differs from running binary"
```

---

## Task 18: Final docs + manual checklist

**Files:**
- Modify: `README.md`
- Create: `docs/manual-test-checklist.md`

- [ ] **Step 18.1: Expand `README.md`**

Sections to add:
- **What it does** (1 paragraph; copy from spec goal).
- **Install** — `./scripts/install-dev.sh`, then click "Install Statusline Integration…".
- **Uninstall** — click Uninstall in dropdown, then `rm -rf ~/Applications/CCUsageStats.app`.
- **How it works** — link to spec.
- **Privacy** — no network calls; reads `~/.claude/projects/...` only via the statusline JSON Claude Code itself feeds us.

- [ ] **Step 18.2: Write `docs/manual-test-checklist.md`**

Reusable smoke checklist. Items:
1. Fresh launch with no `state.json` → menubar `—`, dropdown invites install.
2. After install, run any Claude Code session → menubar updates within 5 s of first prompt.
3. Drop existing 5h % into yellow band (mock state.json with 65%) → icon yellow.
4. Drop into red band (90%) → icon red.
5. Wait 31 minutes idle → icon greys, dropdown shows "Last update 31m ago".
6. Stop Claude Code mid-session → last value persists.
7. Toggle Launch at Login → reboot test (manual).
8. Uninstall → caveman statusline restored exactly.
9. Reinstall after moving the app bundle → mismatch warning, then resolved.

- [ ] **Step 18.3: Commit**

```bash
git add README.md docs
git commit -m "docs: README and manual test checklist"
```

---

## Done

Final state:
- `dist/CCUsageStats.app` builds cleanly via `./scripts/build.sh`.
- All XCTest suites green.
- Manual checklist in `docs/manual-test-checklist.md` passes end-to-end.

## Open Questions Resolved at Plan Time

- **Min macOS:** locked at 13.0 (use `MenuBarExtra` + `SMAppService.mainApp`).
- **Glyph:** SF Symbols `gauge.with.dots.needle.*` — variable to indicate severity, template-renderable so dark/light mode works automatically.
- **CLI status flag:** deferred. Not in this plan.
- **Codesigning / notarization:** dev build only; sign-to-run-locally via Xcode. Distribution flow deferred.

## Out of Scope (Reaffirmed)

- Notifications on threshold crossings
- Historical charts
- Cross-machine cache sync
- Plan-tier UI
- Windows/Linux ports
- Custom color/threshold preferences UI
