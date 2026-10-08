import XCTest
@testable import CCUsageStats

final class AppURLCommandTests: XCTestCase {
    private func parse(_ s: String) -> AppURLCommand? { AppURLCommand(url: URL(string: s)!) }

    func testKnownCommands() {
        XCTAssertEqual(parse("ccusagestats://refresh"), .refresh)
        XCTAssertEqual(parse("ccusagestats://settings?tab=general"), .settings(.general))
        XCTAssertEqual(parse("ccusagestats://settings?tab=accounts"), .settings(.accounts))
        XCTAssertEqual(parse("ccusagestats://settings?tab=alerts"), .settings(.alerts))
    }

    func testSettingsWithoutATabOpensGeneral() {
        XCTAssertEqual(parse("ccusagestats://settings"), .settings(.general))
        XCTAssertEqual(parse("ccusagestats://settings/"), .settings(.general))
    }

    func testSchemeAndCommandAreCaseInsensitive() {
        XCTAssertEqual(parse("CCUsageStats://Refresh"), .refresh)
        XCTAssertEqual(parse("ccusagestats://settings?tab=Alerts"), .settings(.alerts))
    }

    func testUnknownURLsAreRejected() {
        XCTAssertNil(parse("ccusagestats://quit"))
        // A MenuBarExtra panel can't be opened from inside the app (only a
        // real system click opens it), so there is no `open` command.
        XCTAssertNil(parse("ccusagestats://open"))
        XCTAssertNil(parse("ccusagestats://settings?tab=billing"))
        XCTAssertNil(parse("ccusagestats://open/extra"))
        XCTAssertNil(parse("https://open"))
        XCTAssertNil(parse("ccusagestats:open"))
        XCTAssertNil(parse("ccusagestats://refresh#x"))
        XCTAssertNil(parse("ccusagestats://refresh?x=1"))
        XCTAssertNil(parse("ccusagestats://settings?foo=x"))
        XCTAssertNil(parse("ccusagestats://settings?tab=alerts&extra=x"))
        XCTAssertNil(parse("ccusagestats://settings?tab=alerts&tab=general"))
    }
}

final class AppDelegateURLEventTests: XCTestCase {
    func testReadsTheURLFromAGetURLAppleEvent() {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "ccusagestats://settings?tab=alerts"), forKeyword: keyDirectObject)
        XCTAssertEqual(AppDelegate.url(from: event), URL(string: "ccusagestats://settings?tab=alerts"))
        XCTAssertNil(AppDelegate.url(from: NSAppleEventDescriptor.null()))
    }
}
