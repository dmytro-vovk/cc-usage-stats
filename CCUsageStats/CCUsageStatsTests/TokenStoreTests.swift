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

    // MARK: - Expiry round-trip

    func testWriteThenReadStoredPreservesExpiry() throws {
        // Sub-second precision is lost through the epoch-seconds encoding, so
        // compare against a whole-second instant.
        let expiry = Date(timeIntervalSince1970: 1_785_028_800)
        try TokenStore.write("sk-ant-oat01-test", expiresAt: expiry)
        XCTAssertEqual(
            TokenStore.readStored(),
            StoredToken(token: "sk-ant-oat01-test", expiresAt: expiry)
        )
    }

    /// A hand-pasted token has no expiry, and that must survive as nil rather
    /// than becoming a bogus deadline.
    func testWriteWithoutExpiryStoresNil() throws {
        try TokenStore.write("sk-ant-oat01-manual")
        XCTAssertEqual(TokenStore.readStored(), StoredToken(token: "sk-ant-oat01-manual", expiresAt: nil))
    }

    /// Re-importing after a manual paste must not leave the old nil behind, and
    /// vice versa — overwriting replaces the whole envelope.
    func testOverwriteReplacesExpiry() throws {
        let expiry = Date(timeIntervalSince1970: 1_785_028_800)
        try TokenStore.write("sk-ant-oat01-imported", expiresAt: expiry)
        try TokenStore.write("sk-ant-oat01-manual")
        XCTAssertEqual(TokenStore.readStored(), StoredToken(token: "sk-ant-oat01-manual", expiresAt: nil))
    }

    func testReadStoredAbsentReturnsNil() {
        XCTAssertNil(TokenStore.readStored())
    }

    // MARK: - Envelope encoding (no Keychain)

    func testEncodeDecodeRoundTrip() {
        let expiry = Date(timeIntervalSince1970: 1_785_028_800)
        let data = TokenStore.encode(token: "sk-ant-oat01-x", expiresAt: expiry)
        XCTAssertEqual(TokenStore.decode(data), StoredToken(token: "sk-ant-oat01-x", expiresAt: expiry))
    }

    /// Items written by builds that predate the envelope hold the bare token.
    /// They must keep working, with no expiry known for them.
    func testDecodesLegacyBareTokenItem() {
        XCTAssertEqual(
            TokenStore.decode(Data("sk-ant-oat01-legacy".utf8)),
            StoredToken(token: "sk-ant-oat01-legacy", expiresAt: nil)
        )
    }

    func testDecodeRejectsGarbage() {
        XCTAssertNil(TokenStore.decode(Data("not json and not a token".utf8)))
    }

    func testDecodeRejectsEmptyData() {
        XCTAssertNil(TokenStore.decode(Data()))
    }

    func testDecodeRejectsEnvelopeWithoutToken() {
        let data = Data(#"{"expiresAt":1785028800}"#.utf8)
        XCTAssertNil(TokenStore.decode(data))
    }

    func testDecodesEnvelopeWithoutExpiry() {
        let data = Data(#"{"token":"sk-ant-oat01-noexp"}"#.utf8)
        XCTAssertEqual(TokenStore.decode(data), StoredToken(token: "sk-ant-oat01-noexp", expiresAt: nil))
    }
}
