import CryptoKit
import Foundation
import Network
import XCTest

@testable import Perch

/// The phone against a Mac that breaks its own promises.
///
/// `WireRemoteClient` holds every arriving chunk to the byte count the offer
/// stated, and a peer that crosses it costs the session. Our own `WireServer`
/// is held to the same number on the way out, so it can only reach this guard
/// by accident — an older or foreign Mac is what reaches it on purpose. The
/// peer below is hand-rolled for exactly that reason: built out of the real
/// server it would stop being bad the moment the server's own guard tightened.
final class WireBadPeerTests: XCTestCase {
    private var inbox: URL!

    override func setUpWithError() throws {
        inbox = FileManager.default.temporaryDirectory
            .appending(path: "WireBadPeer-\(UUID().uuidString)")
            .appending(path: "inbox")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: inbox.deletingLastPathComponent())
    }

    /// The Mac offers N bytes and then streams more than N. Nothing may land,
    /// and the session is finished: the chunks already on their way would
    /// otherwise answer the *next* request — a `list()` replying with file
    /// bytes. The phone must say so from its own state, before it asks.
    func testAMacThatStreamsPastItsOfferEndsTheSessionInsteadOfDesyncingIt() async throws {
        // No pairing: both halves of this session are ours, so the device key
        // both sides derive from is simply a number they already agree on.
        let deviceKey = Data(repeating: 0x5A, count: 32)
        let itemID = UUID()
        let peer = OverrunPeer(deviceKey: deviceKey, itemID: itemID)
        try peer.start()
        defer { peer.stop() }

        let client = try await WireRemoteClient.connect(
            to: try await peer.endpoint(),
            deviceID: UUID(),
            deviceKey: deviceKey
        )

        do {
            _ = try await client.fetch(itemID, into: inbox)
            XCTFail("Bytes past the offer must not land")
        } catch WireClientError.peerFailure {
            // Expected: a chunk that crosses the offer is a peer bug, stated
            // as one rather than written to disk.
        }
        XCTAssertEqual(try contents(of: inbox), [], "no partial and no wrongly-named file may survive")

        do {
            _ = try await client.list()
            XCTFail("A session abandoned mid-item must not answer another request")
        } catch WireClientError.sessionLost {
            // Expected.
        }
        // The peer is still perfectly willing to answer a list; the refusal is
        // the phone's own, taken before the request went anywhere near the
        // backlog of chunk frames still in the socket.
        XCTAssertEqual(peer.listRequestCount(), 0)

        await client.close()
    }

    /// What the phone actually has in a fetch directory, hidden `.partial`
    /// spools included — the whole point of that assertion.
    private func contents(of directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}

/// A Mac that offers fewer bytes than it then streams: the shape of one whose
/// file grew after it was hashed, and of any peer whose sender never checked.
///
/// It speaks the protocol from the hello onwards and nothing else — no
/// pairing, and deliberately no Bonjour service, so it is reachable only by
/// the test that dials it.
private final class OverrunPeer: @unchecked Sendable {
    /// What the offer claims. Small, so the phone accepts all of it before the
    /// first byte too many arrives.
    static let offeredByteCount = 1 << 10
    /// And what comes after it. Several frames, because one stranded frame
    /// would not be a backlog — the desync this guards against is the next
    /// request reading a queue of them as its reply.
    static let overrunChunkSize = 64 << 10
    static let overrunChunks = 4

    private let deviceKey: Data
    private let itemID: UUID
    private let lock = NSLock()
    private var listener: NWListener?
    private var connection: WireConnection?
    private var listRequests = 0

    init(deviceKey: Data, itemID: UUID) {
        self.deviceKey = deviceKey
        self.itemID = itemID
    }

    func start() throws {
        let listener = try NWListener(using: NWParameters.tcp)
        listener.newConnectionHandler = { [weak self] raw in
            guard let self else {
                raw.cancel()
                return
            }
            let connection = WireConnection(connection: raw)
            lock.withLock { self.connection = connection }
            Task { await self.run(connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        lock.withLock { self.listener = listener }
    }

    func stop() {
        let (listener, connection) = lock.withLock {
            defer {
                self.listener = nil
                self.connection = nil
            }
            return (self.listener, self.connection)
        }
        listener?.cancel()
        Task { await connection?.cancel() }
    }

    /// How many times the phone asked for a shelf listing. Zero is the
    /// assertion: a lost session is answered locally.
    func listRequestCount() -> Int {
        lock.withLock { listRequests }
    }

    /// Where to dial, once Network.framework has bound the listener a port.
    ///
    /// Named error rather than a bare timeout: xcodebuild prints a duration,
    /// and a red run has to say which wait ran out. The budget is a
    /// failure-path number — a healthy run leaves after a poll or two.
    func endpoint(timeout: Duration = .seconds(30)) async throws -> NWEndpoint {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let raw = lock.withLock({ listener?.port?.rawValue }),
               raw != 0,
               let port = NWEndpoint.Port(rawValue: raw) {
                return .hostPort(host: .ipv4(.loopback), port: port)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw BadPeerWait.neverBoundAPort(timeout)
    }

    enum BadPeerWait: Error, CustomStringConvertible {
        case neverBoundAPort(Duration)

        var description: String {
            switch self {
            case let .neverBoundAPort(timeout):
                "The bad peer's listener never bound a port in \(timeout)."
            }
        }
    }

    // MARK: - The session

    private func run(_ connection: WireConnection) async {
        do {
            try await connection.start()
            guard case let .hello(_, _, phoneNonce) = try await connection.receivePlaintextMessage() else {
                return
            }
            let macNonce = WireCrypto.randomSecret(16)
            try await connection.sendPlaintext(.helloAck(macName: "Bad Peer", nonce: macNonce))
            let keys = WireCrypto.sessionKeys(
                deviceKey: SymmetricKey(data: deviceKey),
                phoneNonce: phoneNonce,
                macNonce: macNonce
            )
            await connection.secure(
                send: FrameCryptor(key: keys.macToPhone),
                receive: FrameCryptor(key: keys.phoneToMac)
            )

            while true {
                switch try await connection.receive() {
                case let .control(.fetchItem(requested)) where requested == itemID:
                    try await overrun(on: connection)
                case .control(.shelfListRequest):
                    // Answered, and correctly — so a phone that reaches here
                    // proves it asked, which is the thing that must not happen.
                    lock.withLock { listRequests += 1 }
                    try await connection.send(.control(.shelfList(entries: [])))
                case .control(.bye):
                    return
                default:
                    continue
                }
            }
        } catch {
            // The phone stops reading part-way through by design, so every
            // send after that point is expected to fail eventually. There is
            // nobody left to tell.
        }
    }

    private func overrun(on connection: WireConnection) async throws {
        let promised = Data(repeating: 0xE1, count: Self.offeredByteCount)
        try await connection.send(.control(.offer(transferID: UUID(), items: [
            OfferedItem(
                id: itemID,
                displayName: "overrun.bin",
                contentTypeIdentifier: nil,
                kindHint: "file",
                byteCount: Int64(promised.count),
                // The digest of what was offered, not of what is sent: a Mac
                // whose file grew hashed the smaller one.
                sha256: Data(SHA256.hash(data: promised))
            ),
        ])))
        // Exactly the offer's worth, which the phone takes…
        try await connection.send(.chunk(itemID: itemID, offset: 0, data: promised))
        // …and then the bytes it never agreed to hold.
        var offset = Int64(promised.count)
        for _ in 0..<Self.overrunChunks {
            let extra = Data(repeating: 0xE2, count: Self.overrunChunkSize)
            try await connection.send(.chunk(itemID: itemID, offset: offset, data: extra))
            offset += Int64(extra.count)
        }
        try await connection.send(.control(.itemDone(itemID: itemID)))
    }
}
