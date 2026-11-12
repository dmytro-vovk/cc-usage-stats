import XCTest
@testable import CCUsageStats

/// `AppLinks.website` force-unwraps a string literal, so a typo that made the
/// URL unparseable would trap at launch. This turns that into a test failure.
final class AppLinksTests: XCTestCase {
    /// What the footer's version label, "Update available" and the update
    /// notification open: the site's download page, not GitHub.
    func testWebsiteURLIsTheProjectSite() {
        XCTAssertEqual(AppLinks.website.scheme, "https")
        XCTAssertEqual(AppLinks.website.host, "ccusagestats.app")
        XCTAssertEqual(AppLinks.website.path, "/")
    }
}
