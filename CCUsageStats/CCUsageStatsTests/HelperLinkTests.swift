import XCTest
@testable import CCUsageStats

final class HelperLinkTests: XCTestCase {
    private var dir: URL!
    private var link: URL { dir.appendingPathComponent("bin/ccusagestats") }
    private var exe: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("helper-link-\(UUID().uuidString)")
        exe = dir.appendingPathComponent("A/CCUsageStats.app/Contents/MacOS/CCUsageStats")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: exe.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testLiveLinkPathIsUnderApplicationSupport() {
        XCTAssertEqual(HelperLink.link(in: Paths.liveAppSupportDir).path,
                       Paths.liveAppSupportDir.appendingPathComponent("bin/ccusagestats").path)
    }

    func testCreatesTheLinkAndItsDirectory() throws {
        XCTAssertEqual(try HelperLink.update(link: link, target: exe.path), link.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), exe.path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: link.path))
    }

    func testRepointsAtTheRunningCopy() throws {
        let moved = dir.appendingPathComponent("B/CCUsageStats.app/Contents/MacOS/CCUsageStats")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: moved.path, contents: Data())
        _ = try HelperLink.update(link: link, target: exe.path)
        _ = try HelperLink.update(link: link, target: moved.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), moved.path)
        _ = try HelperLink.update(link: link, target: moved.path)  // idempotent
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), moved.path)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: link.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["ccusagestats"], "no staging files left behind")
    }

    func testNeverReplacesSomethingThatIsNotOurSymlink() throws {
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: link.path, contents: Data("theirs".utf8))
        XCTAssertThrowsError(try HelperLink.update(link: link, target: exe.path))
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "theirs")

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        XCTAssertThrowsError(try HelperLink.update(link: link, target: exe.path))
    }

    func testRefusesASymlinkedBinDirectory() throws {
        let elsewhere = dir.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link.deletingLastPathComponent(), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try HelperLink.update(link: link, target: exe.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    func testTranslocatedCopiesAreNotLinked() {
        XCTAssertTrue(HelperLink.isTranslocated("/private/var/folders/x/T/AppTranslocation/1234/d/CCUsageStats.app/Contents/MacOS/CCUsageStats"))
        XCTAssertFalse(HelperLink.isTranslocated("/Applications/CCUsageStats.app/Contents/MacOS/CCUsageStats"))
        XCTAssertNil(try HelperLink.install(
            appSupport: dir,
            executable: "/private/var/folders/x/T/AppTranslocation/1234/d/CCUsageStats.app/Contents/MacOS/CCUsageStats"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
    }

    func testRegistrationCommandIsTheLinkOnlyWhileItLeadsHere() throws {
        XCTAssertEqual(HelperLink.registrationCommand(link: link, executable: exe.path), exe.path, "no link yet")
        _ = try HelperLink.install(appSupport: dir, executable: exe.path)
        XCTAssertEqual(HelperLink.registrationCommand(link: link, executable: exe.path), link.path)
        XCTAssertEqual(HelperLink.registrationCommand(link: link, executable: "/elsewhere/CCUsageStats"), "/elsewhere/CCUsageStats",
                       "the link leads to another copy")
    }

    func testBundleExecutablePathsAreRecognised() {
        XCTAssertTrue(HelperLink.isBundleExecutable("/Applications/CCUsageStats.app/Contents/MacOS/CCUsageStats"))
        XCTAssertTrue(HelperLink.isBundleExecutable("/Users/u/Downloads/CCUsageStats 2.app/Contents/MacOS/CCUsageStats"))
        XCTAssertFalse(HelperLink.isBundleExecutable("/Users/u/Library/Application Support/cc-usage-stats/bin/ccusagestats"))
        XCTAssertFalse(HelperLink.isBundleExecutable("/usr/local/bin/something-else"))
    }
}
