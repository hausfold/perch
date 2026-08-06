import CryptoKit
import Foundation
import Network

public enum WireClientError: LocalizedError {
    case refused(String)
    case peerFailure(String)
    case unexpectedReply
    case fileUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .refused(reason): reason
        case let .peerFailure(reason): reason
        case .unexpectedReply: "The Mac sent an unexpected reply."
        case let .fileUnreadable(name): "\(name) could not be read for sending."
        }
    }
}

/// The phone's half of pairing.
public enum WirePairingClient {
    /// Runs the whole pairing handshake against `endpoint`. The `confirm`
    /// closure shows the six-digit code and resolves when the person accepts
    /// or rejects it on the phone; the Mac side is doing the same thing with
    /// the same code.
    public static func pair(
        offer: PairingOffer,
        endpoint: NWEndpoint,
        deviceID: UUID,
        deviceName: String,
        confirm: @Sendable (String) async -> Bool
    ) async throws -> PairedPeer {
        let connection = WireConnection(to: endpoint)
        defer { Task { await connection.cancel() } }
        try await connection.start()

        let phonePrivate = Curve25519.KeyAgreement.PrivateKey()
        let phonePublic = phonePrivate.publicKey.rawRepresentation
        try await connection.sendPlaintext(.pairRequest(
            version: WireProtocol.version,
            deviceID: deviceID,
            deviceName: deviceName,
            publicKey: phonePublic,
            auth: WireCrypto.pairingAuth(
                secret: offer.secret,
                context: "perch pair phone v1",
                parts: [deviceID.data, Data(deviceName.utf8), phonePublic]
            )
        ))

        let response = try await connection.receivePlaintextMessage()
        guard case let .pairResponse(macID, macName, macPublicKey, auth) = response else {
            if case let .pairRefused(reason) = response {
                throw WireClientError.refused(reason)
            }
            throw WireClientError.unexpectedReply
        }
        guard macID == offer.macID,
              WireCrypto.verifyPairingAuth(
                  auth,
                  secret: offer.secret,
                  context: "perch pair mac v1",
                  parts: [macID.data, Data(macName.utf8), macPublicKey, phonePublic]
              )
        else {
            throw WireClientError.refused("That Mac did not prove it showed the code you scanned.")
        }

        let deviceKey = try WireCrypto.deviceKey(
            privateKey: phonePrivate,
            peerPublicKey: macPublicKey,
            pairingSecret: offer.secret
        )
        let code = WireCrypto.confirmationCode(
            pairingSecret: offer.secret,
            phonePublicKey: phonePublic,
            macPublicKey: macPublicKey
        )
        guard await confirm(code) else {
            throw WireClientError.refused("Pairing was cancelled on this device.")
        }

        let keyData = deviceKey.withUnsafeBytes { Data($0) }
        try await connection.sendPlaintext(.pairConfirm(auth: WireCrypto.pairingAuth(
            secret: keyData,
            context: "perch pair confirm v1",
            parts: [deviceID.data]
        )))

        switch try await connection.receivePlaintextMessage() {
        case .pairStored:
            return PairedPeer(id: macID, name: macName, deviceKey: keyData)
        case let .pairRefused(reason):
            throw WireClientError.refused(reason)
        default:
            throw WireClientError.unexpectedReply
        }
    }
}

/// The hello exchange that opens every phone-initiated session, after which
/// the connection is sealed in both directions.
///
/// Deliveries and shelf browsing share it: the Mac never dials, so *every*
/// conversation starts here, and a session is free to do both.
public enum WireSession {
    public static func open(
        to endpoint: NWEndpoint,
        deviceID: UUID,
        deviceKey: Data
    ) async throws -> WireConnection {
        let connection = WireConnection(to: endpoint)
        do {
            try await connection.start()
            let phoneNonce = WireCrypto.randomSecret(16)
            try await connection.sendPlaintext(.hello(
                version: WireProtocol.version,
                deviceID: deviceID,
                nonce: phoneNonce
            ))
            let ack = try await connection.receivePlaintextMessage()
            guard case let .helloAck(_, macNonce) = ack else {
                if case let .failure(_, message) = ack {
                    throw WireClientError.peerFailure(message)
                }
                throw WireClientError.unexpectedReply
            }
            let keys = WireCrypto.sessionKeys(
                deviceKey: SymmetricKey(data: deviceKey),
                phoneNonce: phoneNonce,
                macNonce: macNonce
            )
            await connection.secure(
                send: FrameCryptor(key: keys.phoneToMac),
                receive: FrameCryptor(key: keys.macToPhone)
            )
            return connection
        } catch {
            await connection.cancel()
            throw error
        }
    }
}

/// One item the phone wants to deliver.
public struct OutgoingItem: Sendable {
    public let offered: OfferedItem
    public let fileURL: URL

    public init(offered: OfferedItem, fileURL: URL) {
        self.offered = offered
        self.fileURL = fileURL
    }
}

/// Everything that can happen to an offered item, in delivery order.
public enum TransferEvent: Sendable, Equatable {
    case refused(itemID: UUID, reason: String)
    case sending(itemID: UUID)
    case progress(itemID: UUID, sent: Int64, of: Int64)
    case stored(itemID: UUID)
    case failed(itemID: UUID, reason: String)
}

/// The phone's half of a transfer session: hello, offer, stream, acks.
public enum WireTransferClient {
    public static func deliver(
        _ items: [OutgoingItem],
        to endpoint: NWEndpoint,
        deviceID: UUID,
        deviceKey: Data,
        onEvent: @Sendable (TransferEvent) async -> Void
    ) async throws {
        guard !items.isEmpty else { return }
        let connection = try await WireSession.open(
            to: endpoint,
            deviceID: deviceID,
            deviceKey: deviceKey
        )
        defer { Task { await connection.cancel() } }

        let transferID = UUID()
        try await connection.send(.control(.offer(
            transferID: transferID,
            items: items.map(\.offered)
        )))
        guard case let .accept(_, acceptedIDs, refused) = try await connection.receiveMessage() else {
            throw WireClientError.unexpectedReply
        }
        for refusal in refused {
            await onEvent(.refused(itemID: refusal.id, reason: refusal.reason))
        }

        let acceptedSet = Set(acceptedIDs)
        for item in items where acceptedSet.contains(item.offered.id) {
            await onEvent(.sending(itemID: item.offered.id))
            do {
                try await WireStreaming.send(item, over: connection) { sent, total in
                    await onEvent(.progress(itemID: item.offered.id, sent: sent, of: total))
                }
            } catch let error as WireClientError {
                await onEvent(.failed(itemID: item.offered.id, reason: error.localizedDescription))
                throw error
            }
            try await connection.send(.control(.itemDone(itemID: item.offered.id)))
            switch try await connection.receiveMessage() {
            case let .stored(itemID):
                await onEvent(.stored(itemID: itemID))
            case let .itemFailed(itemID, reason):
                await onEvent(.failed(itemID: itemID, reason: reason))
            case let .failure(_, message):
                throw WireClientError.peerFailure(message)
            default:
                throw WireClientError.unexpectedReply
            }
        }
        try await connection.send(.control(.bye))
    }
}
