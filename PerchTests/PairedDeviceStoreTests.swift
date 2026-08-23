import Security
import XCTest
@testable import Perch

/// #12: Settings ▸ Devices said "No devices paired yet" while the phone in the
/// room was delivering to the shelf.
///
/// **What these prove, and what they do not.** They prove the store itself
/// round-trips — store, read one, list all, revoke, re-pair — on the file-based
/// Keychain perch is obliged to use, in a signed sandboxed host as well as an
/// unsigned one. So the enumeration is *not* what #12 is, and #82's two-step
/// read does work. They do not reproduce #12; that needs the paired phone and
/// the installed Developer-ID build, and `all()` now logs its row count either
/// way so the next pairing says which of the three outcomes it is.
///
/// They also pin the two constraints that make this file look the way it does:
/// `kSecMatchLimitAll` with `kSecReturnData` is `errSecParam` here, and the
/// data-protection Keychain — which would allow it — is `errSecMissingEntitlement`
/// for a binary with no Keychain access group, which perch cannot have without a
/// provisioning profile it does not ship with.
final class PairedDeviceStoreTests: XCTestCase {
    private var service = ""
    private var store: PairedDeviceStore!

    override func setUp() {
        super.setUp()
        // A service of its own per test: the machine running this has real
        // pairings, and a test must neither read nor delete them.
        service = "com.hausfold.perch.tests.\(UUID().uuidString)"
        store = PairedDeviceStore(service: service)
    }

    override func tearDown() {
        store.all().forEach { store.revoke($0.id) }
        store = nil
        super.tearDown()
    }

    private func peer(_ name: String, pairedAt: Date = Date()) -> PairedPeer {
        PairedPeer(
            id: UUID(),
            name: name,
            deviceKey: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
            pairedAt: pairedAt
        )
    }

    private func store(_ peer: PairedPeer) throws {
        try store.store(peer)
    }

    // MARK: - The round trip

    func testAStoredDeviceIsBothReadableAndListable() throws {
        let phone = peer("Test iPhone")
        try store(phone)

        // The half that always worked.
        XCTAssertEqual(store.peer(for: phone.id), phone)
        // The half that lied.
        XCTAssertEqual(store.all(), [phone])
    }

    func testEveryStoredDeviceIsListedOldestFirst() throws {
        let older = peer("iPad", pairedAt: Date(timeIntervalSince1970: 1_000))
        let newer = peer("iPhone", pairedAt: Date(timeIntervalSince1970: 2_000))
        try store(newer)
        try store(older)

        XCTAssertEqual(store.all().map(\.name), ["iPad", "iPhone"])
    }

    func testAnEmptyStoreListsNothingRatherThanFailing() {
        XCTAssertEqual(store.all(), [])
    }

    func testRevokingRemovesADeviceFromBothReadAndList() throws {
        let phone = peer("Test iPhone")
        let tablet = peer("Test iPad")
        try store(phone)
        try store(tablet)

        store.revoke(phone.id)

        XCTAssertNil(store.peer(for: phone.id))
        XCTAssertEqual(store.all(), [tablet])
    }

    func testRepairingTheSameDeviceReplacesItInsteadOfDuplicating() throws {
        let first = peer("iPhone")
        let again = PairedPeer(
            id: first.id,
            name: "iPhone renamed",
            deviceKey: Data(repeating: 7, count: 32),
            pairedAt: first.pairedAt
        )
        try store(first)
        try store(again)

        XCTAssertEqual(store.all(), [again])
    }

    // MARK: - The query shapes

    private typealias Query = PairedDeviceStore.Query

    private func allQueries() -> [(String, [String: Any])] {
        let account = UUID()
        return [
            ("listAccounts", Query.listAccounts(service: service)),
            ("read", Query.read(service: service, account: account)),
            ("add", Query.add(service: service, account: account, data: Data("x".utf8))),
            ("delete/item", Query.item(service: service, account: account)),
        ]
    }

    func testEveryQueryIsScopedToTheServiceAndTheGenericPasswordClass() {
        for (name, query) in allQueries() {
            XCTAssertEqual(query[kSecAttrService as String] as? String, service, name)
            XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String, name)
        }
    }

    /// The listing must stay two steps. Combining them is the `errSecParam`
    /// #82 found — asserted against the live Keychain below, not just in prose.
    func testTheAccountListingAsksForAttributesOnlyNotData() {
        let query = Query.listAccounts(service: service)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitAll as String)
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertNil(query[kSecReturnData as String], "adding this is errSecParam — see the next test")
        XCTAssertNil(query[kSecAttrAccount as String], "listing is not scoped to one device")
    }

    func testReadsAndDeletesAreScopedToOneDevice() {
        let account = UUID()
        for query in [
            Query.read(service: service, account: account),
            Query.item(service: service, account: account),
        ] {
            XCTAssertEqual(query[kSecAttrAccount as String] as? String, account.uuidString)
            XCTAssertNil(query[kSecMatchLimit as String])
        }
    }

    func testAStoredDeviceKeyUnlocksOnlyAfterFirstUnlock() {
        let query = Query.add(service: service, account: UUID(), data: Data("x".utf8))
        XCTAssertEqual(
            query[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlock as String
        )
    }

    // MARK: - Why the code is shaped this way (measured, not asserted from docs)

    /// The reason `all()` is two reads. If this ever starts succeeding, the
    /// walk in `all()` can collapse into one query.
    func testAskingThisKeychainForEveryItemAndItsDataIsErrSecParam() throws {
        try store(peer("iPhone"))
        var query = Query.listAccounts(service: service)
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        XCTAssertEqual(
            SecItemCopyMatching(query as CFDictionary, &result),
            errSecParam,
            "limit-all + return-data is supposed to be refused here"
        )
        // ...while the two-step form finds the same item.
        XCTAssertEqual(store.all().count, 1)
    }

    /// The reason perch cannot simply move to the data-protection Keychain,
    /// which *does* allow limit-all together with return-data. Naming a Keychain
    /// access group needs a `keychain-access-groups` entitlement; a
    /// Developer-ID binary carrying one with no provisioning profile — which is
    /// exactly how perch ships — is SIGKILLed at exec, and the App Group perch
    /// does have is not accepted as a substitute.
    func testTheDataProtectionKeychainRefusesAProcessWithNoAccessGroup() {
        let account = UUID()
        var query = Query.add(service: service, account: account, data: Data("x".utf8))
        query[kSecUseDataProtectionKeychain as String] = true

        let status = SecItemAdd(query as CFDictionary, nil)
        XCTAssertEqual(
            status,
            errSecMissingEntitlement,
            "if this ever passes, revisit the type comment on PairedDeviceStore"
        )
        if status == errSecSuccess {
            // On the day this stops being refused, tearDown cannot reach it —
            // it queries the other Keychain — so clean up the same account here.
            var cleanup = Query.item(service: service, account: account)
            cleanup[kSecUseDataProtectionKeychain as String] = true
            SecItemDelete(cleanup as CFDictionary)
        }
    }
}
