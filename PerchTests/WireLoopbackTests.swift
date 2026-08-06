import CryptoKit
import Foundation
import Network
import XCTest

@testable import Perch

/// The whole wire, no UI: a real listener on a real localhost port, a real
/// client, pairing followed by delivery, bytes verified on the far side.
final class WireLoopbackTests: XCTestCase {
    private var spoolDirectory: URL!
    private var shelfDirectory: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "WireLoopback-\(UUID().uuidString)")
        spoolDirectory = base.appending(path: "spool")
        shelfDirectory = base.appending(path: "shelf")
        try FileManager.default.createDirectory(at: spoolDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shelfDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: spoolDirectory.deletingLastPathComponent()
        )
    }

    func testPairThenDeliverTwoItems() async throws {
        let identity = MacIdentity(id: UUID(), name: "Loopback Mac")
        let delegate = LoopbackDelegate(
            identity: identity,
            spool: spoolDirectory,
            shelf: shelfDirectory,
            pairingSecret: nil
        )
        let server = WireServer(delegate: delegate)
        try server.start(identity: identity)
        defer { server.stop() }
        let port = try XCTUnwrap(waitForPort(server))

        // --- Pair ---
        let offer = PairingOffer(
            macID: identity.id,
            macName: identity.name,
            secret: WireCrypto.randomSecret()
        )
        delegate.setPairingSecret(offer.secret)
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let deviceID = UUID()
        let mac = try await WirePairingClient.pair(
            offer: offer,
            endpoint: endpoint,
            deviceID: deviceID,
            deviceName: "Test iPhone"
        ) { code in
            // Both sides derive the code from the same transcript; the
            // delegate recorded the Mac's.
            XCTAssertEqual(code.count, 6)
            return true
        }
        XCTAssertEqual(mac.id, identity.id)
        XCTAssertEqual(delegate.storedPeer?.id, deviceID)
        XCTAssertEqual(delegate.storedPeer?.deviceKey, mac.deviceKey)

        // --- Deliver ---
        let smallURL = spoolDirectory.appending(path: "hello.txt")
        try Data("hello from the phone".utf8).write(to: smallURL)
        var big = Data(capacity: 3 << 20)
        for index in 0..<(3 << 20) {
            big.append(UInt8(truncatingIfNeeded: index &* 31))
        }
        let bigURL = spoolDirectory.appending(path: "big.bin")
        try big.write(to: bigURL)

        let outgoing = [
            try outgoingItem(for: smallURL, kind: "text"),
            try outgoingItem(for: bigURL, kind: "file"),
        ]
        let events = EventLog()
        try await WireTransferClient.deliver(
            outgoing,
            to: endpoint,
            deviceID: deviceID,
            deviceKey: mac.deviceKey
        ) { event in
            events.append(event)
        }

        let storedIDs = events.stored
        XCTAssertEqual(Set(storedIDs), Set(outgoing.map(\.offered.id)))
        for item in outgoing {
            let landed = shelfDirectory.appending(path: item.offered.displayName)
            let data = try Data(contentsOf: landed)
            XCTAssertEqual(Data(SHA256.hash(data: data)), item.offered.sha256)
        }
    }

    func testUnpairedDeviceIsRefused() async throws {
        let identity = MacIdentity(id: UUID(), name: "Loopback Mac")
        let delegate = LoopbackDelegate(
            identity: identity,
            spool: spoolDirectory,
            shelf: shelfDirectory,
            pairingSecret: nil
        )
        let server = WireServer(delegate: delegate)
        try server.start(identity: identity)
        defer { server.stop() }
        let port = try XCTUnwrap(waitForPort(server))
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)

        let url = spoolDirectory.appending(path: "nope.txt")
        try Data("refused".utf8).write(to: url)
        do {
            try await WireTransferClient.deliver(
                [try outgoingItem(for: url, kind: "text")],
                to: endpoint,
                deviceID: UUID(),
                deviceKey: Data(repeating: 9, count: 32)
            ) { _ in }
            XCTFail("An unpaired device must be refused")
        } catch {
            // Expected: the server answers `failure(.unpaired)` before keys.
        }
    }

    /// Regression: waiting for a Mac that never appears must time out, not
    /// deadlock. The first implementation leaked a continuation here and hung
    /// forever — which is the product's headline "Mac is away" case.
    func testWaitingForAnAbsentMacTimesOut() async {
        let started = Date()
        let endpoint = await WireBrowser.waitFor(macID: UUID(), timeout: .seconds(1))
        XCTAssertNil(endpoint)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    // MARK: - Helpers

    private func waitForPort(_ server: WireServer, attempts: Int = 50) -> UInt16? {
        for _ in 0..<attempts {
            if let port = server.port, port != 0 {
                return port
            }
            usleep(100_000)
        }
        return nil
    }

    private func outgoingItem(for url: URL, kind: String) throws -> OutgoingItem {
        let data = try Data(contentsOf: url)
        return OutgoingItem(
            offered: OfferedItem(
                id: UUID(),
                displayName: url.lastPathComponent,
                contentTypeIdentifier: nil,
                kindHint: kind,
                byteCount: Int64(data.count),
                sha256: Data(SHA256.hash(data: data))
            ),
            fileURL: url
        )
    }
}

/// A wire-server delegate with no UI and no ShelfStore: auto-approves, keeps
/// the one paired peer in memory, commits arrivals into a flat directory.
private final class LoopbackDelegate: WireServerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let macIdentity: MacIdentity
    private let spool: URL
    private let shelf: URL
    private var secret: Data?
    private var peer: PairedPeer?

    init(identity: MacIdentity, spool: URL, shelf: URL, pairingSecret: Data?) {
        macIdentity = identity
        self.spool = spool
        self.shelf = shelf
        secret = pairingSecret
    }

    func setPairingSecret(_ new: Data?) {
        lock.withLock { secret = new }
    }

    var storedPeer: PairedPeer? {
        lock.withLock { peer }
    }

    func identity() -> MacIdentity {
        macIdentity
    }

    func activePairingSecret() -> Data? {
        lock.withLock { secret }
    }

    func approvePairing(deviceID: UUID, deviceName: String, code: String) -> Bool {
        true
    }

    func storePairedPeer(_ newPeer: PairedPeer) throws {
        lock.withLock { peer = newPeer }
    }

    func pairedPeer(for deviceID: UUID) -> PairedPeer? {
        lock.withLock { peer?.id == deviceID ? peer : nil }
    }

    func admit(_ items: [OfferedItem], from peer: PairedPeer) -> (accepted: [OfferedItem], refused: [RefusedItem]) {
        (items, [])
    }

    func spoolDirectory() throws -> URL {
        spool
    }

    func commit(_ item: OfferedItem, stagedFileURL: URL, from peer: PairedPeer) throws {
        try FileManager.default.moveItem(
            at: stagedFileURL,
            to: shelf.appending(path: item.displayName)
        )
    }

    func transferFailed(_ item: OfferedItem, from peer: PairedPeer, reason: String) {}
}

/// Event sink usable from a @Sendable callback.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TransferEvent] = []

    func append(_ event: TransferEvent) {
        lock.withLock { events.append(event) }
    }

    var stored: [UUID] {
        lock.withLock {
            events.compactMap {
                if case let .stored(id) = $0 { return id }
                return nil
            }
        }
    }
}
