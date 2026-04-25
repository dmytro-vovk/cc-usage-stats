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
