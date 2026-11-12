import XCTest
@testable import CCUsageStats

/// `AppLinks.releases` force-unwraps a string literal, so a typo that made the
/// URL unparseable would trap at launch. These assertions turn that into a
/// build-time failure instead.
final class AppLinksTests: XCTestCase {
    func testReleasesURLIsWellFormed() {
        XCTAssertEqual(AppLinks.releases.scheme, "https")
        XCTAssertEqual(AppLinks.releases.host, "github.com")
        XCTAssertEqual(AppLinks.releases.path, "/dmytro-vovk/cc-usage-stats/releases")
    }

    /// The index, not a per-version tag page: dev builds report 0.0.0, which
    /// has no tag and would 404.
    func testReleasesURLIsTheIndexNotATagPage() {
        XCTAssertFalse(AppLinks.releases.absoluteString.contains("/tag/"))
        XCTAssertTrue(AppLinks.releases.absoluteString.hasSuffix("/releases"))
    }

    /// What "Update available" and the update notification open: the site's
    /// download page, not a GitHub release page.
    func testWebsiteURLIsTheProjectSite() {
        XCTAssertEqual(AppLinks.website.scheme, "https")
        XCTAssertEqual(AppLinks.website.host, "ccusagestats.app")
        XCTAssertEqual(AppLinks.website.path, "/")
    }

    func testReleasesURLIsBuiltFromTheRepositoryConstant() {
        XCTAssertTrue(AppLinks.releases.absoluteString.hasPrefix(AppLinks.repository))
    }
}
