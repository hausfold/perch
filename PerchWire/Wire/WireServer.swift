import CryptoKit
import Foundation
import Network
import OSLog

public struct MacIdentity: Sendable, Equatable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Everything the wire server needs from the app hosting it. The server owns
/// sockets, framing, crypto, spooling, and digest verification; the delegate
/// owns identity, pairing policy, admission, and the shelf.
public protocol WireServerDelegate: Sendable {
    func identity() async -> MacIdentity
    /// The open pairing window's secret, or nil when no window is open —
    /// pairing attempts outside a window are refused before any key math.
    func activePairingSecret() async -> Data?
    /// Show the six-digit code and ask the person at the Mac. Blocks until
    /// they answer.
    func approvePairing(deviceID: UUID, deviceName: String, code: String) async -> Bool
    func storePairedPeer(_ peer: PairedPeer) async throws
    func pairedPeer(for deviceID: UUID) async -> PairedPeer?
    /// Admission before a single byte is accepted, mirroring the drag-in rule:
    /// an item that won't fit is never spooled.
    func admit(_ items: [OfferedItem], from peer: PairedPeer) async -> (accepted: [OfferedItem], refused: [RefusedItem])
    /// Where partial files spool. Must be on the same volume as the shelf so
    /// the final commit is an atomic move.
    func spoolDirectory() async throws -> URL
    /// The file is complete and its digest verified — put it on the shelf.
    func commit(_ item: OfferedItem, stagedFileURL: URL, from peer: PairedPeer) async throws
    func transferFailed(_ item: OfferedItem, from peer: PairedPeer, reason: String) async

    // The reverse direction — the shelf as something a paired phone can read
    // and prune, not just deliver into.

    /// The Mac's shelf as this phone should see it.
    func shelfEntries(for peer: PairedPeer) async -> [RemoteEntry]
    /// One shelf item, described and located well enough to stream. Throwing
    /// is the normal answer for "gone" or "not something a phone can hold" —
    /// the reason reaches the phone verbatim.
    ///
    /// Whatever this returns gets exactly one outcome afterwards —
    /// `itemServed` or `serveFailed` — so a delegate can say an item is on its
    /// way and be told how that ended. An item this *throws* on gets neither:
    /// the delegate already knows, it raised the reason itself.
    func readItem(_ itemID: UUID, for peer: PairedPeer) async throws -> OutgoingItem
    /// Every byte reached the phone. Fetching is a copy, so the item is still
    /// on the shelf — this is the end of a transfer, not of an item.
    func itemServed(_ item: OfferedItem, to peer: PairedPeer) async
    /// The item never got there whole: the file changed underfoot, or the
    /// connection went away mid-stream.
    func serveFailed(_ item: OfferedItem, to peer: PairedPeer, reason: String) async
    /// Take an item off the shelf because the phone asked.
    func removeItem(_ itemID: UUID, for peer: PairedPeer) async throws
}

public enum WireServerError: LocalizedError {
    case listenFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .listenFailed(reason): "Perch could not listen for devices: \(reason)"
        }
    }
}

/// The Mac's listening end: advertises `_perch._tcp` over Bonjour and runs
/// one `WireServerSession` per accepted connection.
public final class WireServer: @unchecked Sendable {
    private let delegate: WireServerDelegate
    private let logger = Logger(subsystem: "com.hausfold.perch", category: "WireServer")
    private var listener: NWListener?
    private let lock = NSLock()

    public init(delegate: WireServerDelegate) {
        self.delegate = delegate
    }

    /// Starts listening and advertising. Safe to call again after `stop()`.
    public func start(identity: MacIdentity) throws {
        try lock.withLock {
            guard listener == nil else { return }
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener: NWListener
            do {
                listener = try NWListener(using: parameters)
            } catch {
                throw WireServerError.listenFailed(error.localizedDescription)
            }
            var txt = NWTXTRecord()
            txt["macid"] = identity.id.uuidString
            txt["v"] = String(WireProtocol.version)
            listener.service = NWListener.Service(
                name: identity.name,
                type: WireProtocol.bonjourType,
                txtRecord: txt
            )
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                logger.info("Accepted a connection")
                let session = WireServerSession(
                    connection: WireConnection(connection: connection),
                    delegate: delegate
                )
                Task.detached { await session.run() }
            }
            listener.stateUpdateHandler = { [logger] state in
                switch state {
                case let .failed(error):
                    logger.error("Listener failed: \(error.localizedDescription, privacy: .public)")
                case .ready:
                    logger.info("Listening for paired devices")
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        }
    }

    public func stop() {
        lock.withLock {
            listener?.cancel()
            listener = nil
        }
    }

    public var port: UInt16? {
        lock.withLock { listener?.port?.rawValue }
    }
}

/// One accepted connection, from first frame to close.
public actor WireServerSession {
    private let connection: WireConnection
    private let delegate: WireServerDelegate
    private let logger = Logger(subsystem: "com.hausfold.perch", category: "WireSession")

    /// An item mid-arrival: its spool file, running digest, and byte count.
    private struct InboundItem {
        let offered: OfferedItem
        let spoolURL: URL
        let handle: FileHandle
        var digest = SHA256()
        var received: Int64 = 0
    }

    public init(connection: WireConnection, delegate: WireServerDelegate) {
        self.connection = connection
        self.delegate = delegate
    }

    public func run() async {
        do {
            try await connection.start()
            switch try await connection.receivePlaintextMessage() {
            case let .pairRequest(version, deviceID, deviceName, publicKey, auth):
                try await runPairing(
                    version: version,
                    deviceID: deviceID,
                    deviceName: deviceName,
                    phonePublicKey: publicKey,
                    auth: auth
                )
            case let .hello(version, deviceID, nonce):
                try await runTransferSession(version: version, deviceID: deviceID, phoneNonce: nonce)
            default:
                try await connection.sendPlaintext(.failure(
                    code: .protocolViolation,
                    message: "Expected pairRequest or hello."
                ))
            }
        } catch {
            logger.info("Session ended: \(error.localizedDescription, privacy: .public)")
        }
        await connection.cancel()
    }

    // MARK: - Pairing

    private func runPairing(
        version: Int,
        deviceID: UUID,
        deviceName: String,
        phonePublicKey: Data,
        auth: Data
    ) async throws {
        guard version == WireProtocol.version else {
            try await connection.sendPlaintext(.pairRefused(reason: "This Perch speaks protocol \(WireProtocol.version)."))
            return
        }
        guard let secret = await delegate.activePairingSecret() else {
            try await connection.sendPlaintext(.pairRefused(reason: "No pairing window is open on the Mac."))
            return
        }
        guard WireCrypto.verifyPairingAuth(
            auth,
            secret: secret,
            context: "perch pair phone v1",
            parts: [deviceID.data, Data(deviceName.utf8), phonePublicKey]
        ) else {
            try await connection.sendPlaintext(.pairRefused(reason: "The pairing code did not match."))
            return
        }

        let identity = await delegate.identity()
        let macPrivate = Curve25519.KeyAgreement.PrivateKey()
        let macPublic = macPrivate.publicKey.rawRepresentation
        try await connection.sendPlaintext(.pairResponse(
            macID: identity.id,
            macName: identity.name,
            publicKey: macPublic,
            auth: WireCrypto.pairingAuth(
                secret: secret,
                context: "perch pair mac v1",
                parts: [identity.id.data, Data(identity.name.utf8), macPublic, phonePublicKey]
            )
        ))

        let deviceKey = try WireCrypto.deviceKey(
            privateKey: macPrivate,
            peerPublicKey: phonePublicKey,
            pairingSecret: secret
        )
        let code = WireCrypto.confirmationCode(
            pairingSecret: secret,
            phonePublicKey: phonePublicKey,
            macPublicKey: macPublic
        )

        // The phone confirms with a MAC under the derived key (proving the
        // key agreement landed) while the person at the Mac approves the
        // matching code. Both must say yes.
        guard case let .pairConfirm(confirmAuth) = try await connection.receiveMessage() else {
            try await connection.sendPlaintext(.pairRefused(reason: "The device abandoned pairing."))
            return
        }
        let keyData = deviceKey.withUnsafeBytes { Data($0) }
        guard WireCrypto.verifyPairingAuth(
            confirmAuth,
            secret: keyData,
            context: "perch pair confirm v1",
            parts: [deviceID.data]
        ) else {
            try await connection.sendPlaintext(.pairRefused(reason: "The device failed key confirmation."))
            return
        }

        guard await delegate.approvePairing(deviceID: deviceID, deviceName: deviceName, code: code) else {
            try await connection.sendPlaintext(.pairRefused(reason: "The Mac declined the pairing."))
            return
        }

        try await delegate.storePairedPeer(PairedPeer(
            id: deviceID,
            name: deviceName,
            deviceKey: keyData
        ))
        try await connection.sendPlaintext(.pairStored)
        logger.info("Paired device \(deviceName, privacy: .public)")
    }

    // MARK: - Transfers

    private func runTransferSession(version: Int, deviceID: UUID, phoneNonce: Data) async throws {
        guard version == WireProtocol.version else {
            try await connection.sendPlaintext(.failure(
                code: .protocolViolation,
                message: "This Perch speaks protocol \(WireProtocol.version)."
            ))
            return
        }
        guard let peer = await delegate.pairedPeer(for: deviceID) else {
            try await connection.sendPlaintext(.failure(
                code: .unpaired,
                message: "This device is not paired with this Mac."
            ))
            return
        }

        let identity = await delegate.identity()
        let macNonce = WireCrypto.randomSecret(16)
        try await connection.sendPlaintext(.helloAck(macName: identity.name, nonce: macNonce))

        let keys = WireCrypto.sessionKeys(
            deviceKey: SymmetricKey(data: peer.deviceKey),
            phoneNonce: phoneNonce,
            macNonce: macNonce
        )
        await connection.secure(
            send: FrameCryptor(key: keys.macToPhone),
            receive: FrameCryptor(key: keys.phoneToMac)
        )

        // `accepted` holds every admitted item until its outcome frame went
        // out; whatever is still in it when the session ends — dropped
        // connection mid-item, but also accepted items the phone never got to
        // stream — must be failed, or the Mac's pending tiles (which count
        // against admission) linger until relaunch.
        var accepted: [UUID: OfferedItem] = [:]
        var inbound: [UUID: InboundItem] = [:]
        defer {
            for item in inbound.values {
                try? item.handle.close()
                try? FileManager.default.removeItem(at: item.spoolURL)
            }
            for item in accepted.values {
                Task { [delegate] in
                    await delegate.transferFailed(item, from: peer, reason: "The connection was interrupted.")
                }
            }
        }

        receiveLoop: while true {
            switch try await connection.receive() {
            case let .control(message):
                switch message {
                case let .offer(transferID, items):
                    let decision = await delegate.admit(items, from: peer)
                    for item in decision.accepted {
                        accepted[item.id] = item
                    }
                    try await connection.send(.control(.accept(
                        transferID: transferID,
                        itemIDs: decision.accepted.map(\.id),
                        refused: decision.refused
                    )))
                case let .itemDone(itemID):
                    guard let item = inbound.removeValue(forKey: itemID) else {
                        try await connection.send(.control(.itemFailed(
                            itemID: itemID,
                            reason: "The Mac never saw bytes for that item."
                        )))
                        continue
                    }
                    try item.handle.close()
                    let digest = Data(item.digest.finalize())
                    guard item.received == item.offered.byteCount,
                          digest == item.offered.sha256
                    else {
                        try? FileManager.default.removeItem(at: item.spoolURL)
                        accepted[itemID] = nil
                        await delegate.transferFailed(item.offered, from: peer, reason: "The bytes did not match the offer.")
                        try await connection.send(.control(.itemFailed(
                            itemID: itemID,
                            reason: "The transfer arrived corrupted. Try again."
                        )))
                        continue
                    }
                    do {
                        try await delegate.commit(item.offered, stagedFileURL: item.spoolURL, from: peer)
                        accepted[itemID] = nil
                        try await connection.send(.control(.stored(itemID: itemID)))
                    } catch {
                        try? FileManager.default.removeItem(at: item.spoolURL)
                        accepted[itemID] = nil
                        await delegate.transferFailed(item.offered, from: peer, reason: error.localizedDescription)
                        try await connection.send(.control(.itemFailed(
                            itemID: itemID,
                            reason: error.localizedDescription
                        )))
                    }
                case .shelfListRequest:
                    let entries = await delegate.shelfEntries(for: peer)
                    try await connection.send(.control(.shelfList(entries: entries)))
                case let .fetchItem(itemID):
                    try await serveFetch(itemID, to: peer)
                case let .removeItem(itemID):
                    do {
                        try await delegate.removeItem(itemID, for: peer)
                        try await connection.send(.control(.removeAck(itemID: itemID)))
                    } catch {
                        try await connection.send(.control(.itemFailed(
                            itemID: itemID,
                            reason: error.localizedDescription
                        )))
                    }
                case .bye:
                    break receiveLoop
                default:
                    try await connection.send(.control(.failure(
                        code: .protocolViolation,
                        message: "Unexpected message during a transfer session."
                    )))
                    break receiveLoop
                }
            case let .chunk(itemID, offset, data):
                guard let offered = accepted[itemID] else {
                    try await connection.send(.control(.itemFailed(
                        itemID: itemID,
                        reason: "That item was never accepted."
                    )))
                    continue
                }
                var item: InboundItem
                if let existing = inbound[itemID] {
                    item = existing
                } else {
                    let spool = try await delegate.spoolDirectory()
                    let spoolURL = spool.appending(path: ".\(itemID.uuidString).partial")
                    FileManager.default.createFile(atPath: spoolURL.path, contents: nil)
                    guard let handle = FileHandle(forWritingAtPath: spoolURL.path) else {
                        // Every later chunk for this item would fail the same
                        // way, so end it here rather than leaving the phone
                        // streaming into a tile that will never resolve — and
                        // take the empty spool file with it.
                        try? FileManager.default.removeItem(at: spoolURL)
                        accepted[itemID] = nil
                        await delegate.transferFailed(
                            offered,
                            from: peer,
                            reason: "The Mac could not open a spool file."
                        )
                        try await connection.send(.control(.itemFailed(
                            itemID: itemID,
                            reason: "The Mac could not open a spool file."
                        )))
                        continue
                    }
                    item = InboundItem(offered: offered, spoolURL: spoolURL, handle: handle)
                }
                // Offsets are strictly sequential; anything else is a peer bug.
                guard offset == item.received,
                      item.received + Int64(data.count) <= offered.byteCount
                else {
                    try? item.handle.close()
                    try? FileManager.default.removeItem(at: item.spoolURL)
                    inbound[itemID] = nil
                    accepted[itemID] = nil
                    await delegate.transferFailed(offered, from: peer, reason: "The transfer stream went out of order.")
                    try await connection.send(.control(.itemFailed(
                        itemID: itemID,
                        reason: "The transfer stream went out of order."
                    )))
                    continue
                }
                try item.handle.write(contentsOf: data)
                item.digest.update(data: data)
                item.received += Int64(data.count)
                inbound[itemID] = item
            }
        }
    }

    // MARK: - Serving the shelf back
    //
    // A fetch is a delivery with the roles swapped: the Mac describes the item
    // first (so the phone can size it and hold the bytes to a digest), streams
    // it, then closes it. Fetching is a copy — the item stays on the shelf
    // until someone removes it, on either end.

    private func serveFetch(_ itemID: UUID, to peer: PairedPeer) async throws {
        let outgoing: OutgoingItem
        do {
            outgoing = try await delegate.readItem(itemID, for: peer)
        } catch {
            try await connection.send(.control(.itemFailed(
                itemID: itemID,
                reason: error.localizedDescription
            )))
            return
        }
        do {
            try await connection.send(.control(.offer(
                transferID: UUID(),
                items: [outgoing.offered]
            )))
            try await WireStreaming.send(outgoing, over: connection)
            try await connection.send(.control(.itemDone(itemID: itemID)))
        } catch {
            // The delegate is showing this item as on its way; it hears how it
            // ended even when the socket is the thing that broke.
            await delegate.serveFailed(outgoing.offered, to: peer, reason: error.localizedDescription)
            // The phone is mid-item and waiting; tell it, so it drops the
            // partial rather than hanging on a stream that stopped.
            try await connection.send(.control(.itemFailed(
                itemID: itemID,
                reason: error.localizedDescription
            )))
            return
        }
        await delegate.itemServed(outgoing.offered, to: peer)
    }
}

extension UUID {
    /// The raw 16 bytes, for HMAC transcripts.
    var data: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }
}
