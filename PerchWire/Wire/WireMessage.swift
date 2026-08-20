import Foundation

/// The perch mobile wire protocol, version 1.
///
/// Everything that crosses the network between a phone and a Mac is a
/// length-prefixed frame. Pairing and the session hello are plaintext JSON
/// control messages authenticated by the pairing secret; every frame after the
/// hello exchange is a ChaChaPoly-sealed box. Hand-framed rather than TLS-PSK:
/// `sec_protocol_options_add_pre_shared_key` buys the same confidentiality from
/// a C API with worse testability, and still needs the pairing layer built by
/// hand. See ARCHITECTURE.md, "the wire".
public enum WireProtocol {
    public static let version = 1
    /// The Bonjour service a shelf-holding Mac advertises.
    public static let bonjourType = "_perch._tcp"
    /// Frames above this size are a protocol violation, not a big file — files
    /// travel as chunks well below it.
    public static let maxFrameLength = 4 << 20
    /// File payload bytes per sealed chunk frame.
    public static let chunkSize = 512 << 10
}

/// One item inside a transfer offer: enough for the receiving Mac to decide
/// admission and to verify the bytes that later arrive.
public struct OfferedItem: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let contentTypeIdentifier: String?
    public let kindHint: String
    public let byteCount: Int64
    public let sha256: Data

    public init(
        id: UUID,
        displayName: String,
        contentTypeIdentifier: String?,
        kindHint: String,
        byteCount: Int64,
        sha256: Data
    ) {
        self.id = id
        self.displayName = displayName
        self.contentTypeIdentifier = contentTypeIdentifier
        self.kindHint = kindHint
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct RefusedItem: Codable, Sendable, Equatable {
    public let id: UUID
    public let reason: String

    public init(id: UUID, reason: String) {
        self.id = id
        self.reason = reason
    }
}

/// One item of the Mac's shelf as shown to a paired phone: enough to list,
/// order, and decide whether it can be fetched.
public struct RemoteEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let kindHint: String
    public let contentTypeIdentifier: String?
    public let byteCount: Int64?
    public let addedAt: Date

    public init(
        id: UUID,
        displayName: String,
        kindHint: String,
        contentTypeIdentifier: String?,
        byteCount: Int64?,
        addedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.kindHint = kindHint
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
        self.addedAt = addedAt
    }
}

/// Every control message that can appear on the wire. JSON with a `t`
/// discriminator so a foreign or future peer fails loudly, not quietly.
public enum WireMessage: Sendable, Equatable {
    case pairRequest(version: Int, deviceID: UUID, deviceName: String, publicKey: Data, auth: Data)
    case pairResponse(macID: UUID, macName: String, publicKey: Data, auth: Data)
    case pairConfirm(auth: Data)
    case pairStored
    case pairRefused(reason: String)

    case hello(version: Int, deviceID: UUID, nonce: Data)
    case helloAck(macName: String, nonce: Data)

    case offer(transferID: UUID, items: [OfferedItem])
    case accept(transferID: UUID, itemIDs: [UUID], refused: [RefusedItem])
    case itemDone(itemID: UUID)
    case stored(itemID: UUID)
    case itemFailed(itemID: UUID, reason: String)
    case bye

    // The reverse direction: a paired phone browsing, pulling from, and
    // pruning the Mac's shelf. Always phone-initiated — the Mac never dials.
    case shelfListRequest
    case shelfList(entries: [RemoteEntry])
    case fetchItem(itemID: UUID)
    case removeItem(itemID: UUID)
    case removeAck(itemID: UUID)

    case failure(code: FailureCode, message: String)

    public enum FailureCode: String, Codable, Sendable {
        case unpaired
        case badAuth
        case protocolViolation
        case shelfUnavailable
        case internalError
    }
}

extension WireMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case t
        case version, deviceID, deviceName, publicKey, auth
        case macID, macName, nonce, reason
        case transferID, items, itemIDs, refused, itemID
        case entries
        case code, message
    }

    private enum Tag: String, Codable {
        case pairRequest, pairResponse, pairConfirm, pairStored, pairRefused
        case hello, helloAck
        case offer, accept, itemDone, stored, itemFailed, bye
        case shelfListRequest, shelfList, fetchItem, removeItem, removeAck
        case failure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Tag.self, forKey: .t) {
        case .pairRequest:
            self = try .pairRequest(
                version: container.decode(Int.self, forKey: .version),
                deviceID: container.decode(UUID.self, forKey: .deviceID),
                deviceName: container.decode(String.self, forKey: .deviceName),
                publicKey: container.decode(Data.self, forKey: .publicKey),
                auth: container.decode(Data.self, forKey: .auth)
            )
        case .pairResponse:
            self = try .pairResponse(
                macID: container.decode(UUID.self, forKey: .macID),
                macName: container.decode(String.self, forKey: .macName),
                publicKey: container.decode(Data.self, forKey: .publicKey),
                auth: container.decode(Data.self, forKey: .auth)
            )
        case .pairConfirm:
            self = try .pairConfirm(auth: container.decode(Data.self, forKey: .auth))
        case .pairStored:
            self = .pairStored
        case .pairRefused:
            self = try .pairRefused(reason: container.decode(String.self, forKey: .reason))
        case .hello:
            self = try .hello(
                version: container.decode(Int.self, forKey: .version),
                deviceID: container.decode(UUID.self, forKey: .deviceID),
                nonce: container.decode(Data.self, forKey: .nonce)
            )
        case .helloAck:
            self = try .helloAck(
                macName: container.decode(String.self, forKey: .macName),
                nonce: container.decode(Data.self, forKey: .nonce)
            )
        case .offer:
            self = try .offer(
                transferID: container.decode(UUID.self, forKey: .transferID),
                items: container.decode([OfferedItem].self, forKey: .items)
            )
        case .accept:
            self = try .accept(
                transferID: container.decode(UUID.self, forKey: .transferID),
                itemIDs: container.decode([UUID].self, forKey: .itemIDs),
                refused: container.decode([RefusedItem].self, forKey: .refused)
            )
        case .itemDone:
            self = try .itemDone(itemID: container.decode(UUID.self, forKey: .itemID))
        case .stored:
            self = try .stored(itemID: container.decode(UUID.self, forKey: .itemID))
        case .itemFailed:
            self = try .itemFailed(
                itemID: container.decode(UUID.self, forKey: .itemID),
                reason: container.decode(String.self, forKey: .reason)
            )
        case .bye:
            self = .bye
        case .shelfListRequest:
            self = .shelfListRequest
        case .shelfList:
            self = try .shelfList(entries: container.decode([RemoteEntry].self, forKey: .entries))
        case .fetchItem:
            self = try .fetchItem(itemID: container.decode(UUID.self, forKey: .itemID))
        case .removeItem:
            self = try .removeItem(itemID: container.decode(UUID.self, forKey: .itemID))
        case .removeAck:
            self = try .removeAck(itemID: container.decode(UUID.self, forKey: .itemID))
        case .failure:
            self = try .failure(
                code: container.decode(FailureCode.self, forKey: .code),
                message: container.decode(String.self, forKey: .message)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pairRequest(version, deviceID, deviceName, publicKey, auth):
            try container.encode(Tag.pairRequest, forKey: .t)
            try container.encode(version, forKey: .version)
            try container.encode(deviceID, forKey: .deviceID)
            try container.encode(deviceName, forKey: .deviceName)
            try container.encode(publicKey, forKey: .publicKey)
            try container.encode(auth, forKey: .auth)
        case let .pairResponse(macID, macName, publicKey, auth):
            try container.encode(Tag.pairResponse, forKey: .t)
            try container.encode(macID, forKey: .macID)
            try container.encode(macName, forKey: .macName)
            try container.encode(publicKey, forKey: .publicKey)
            try container.encode(auth, forKey: .auth)
        case let .pairConfirm(auth):
            try container.encode(Tag.pairConfirm, forKey: .t)
            try container.encode(auth, forKey: .auth)
        case .pairStored:
            try container.encode(Tag.pairStored, forKey: .t)
        case let .pairRefused(reason):
            try container.encode(Tag.pairRefused, forKey: .t)
            try container.encode(reason, forKey: .reason)
        case let .hello(version, deviceID, nonce):
            try container.encode(Tag.hello, forKey: .t)
            try container.encode(version, forKey: .version)
            try container.encode(deviceID, forKey: .deviceID)
            try container.encode(nonce, forKey: .nonce)
        case let .helloAck(macName, nonce):
            try container.encode(Tag.helloAck, forKey: .t)
            try container.encode(macName, forKey: .macName)
            try container.encode(nonce, forKey: .nonce)
        case let .offer(transferID, items):
            try container.encode(Tag.offer, forKey: .t)
            try container.encode(transferID, forKey: .transferID)
            try container.encode(items, forKey: .items)
        case let .accept(transferID, itemIDs, refused):
            try container.encode(Tag.accept, forKey: .t)
            try container.encode(transferID, forKey: .transferID)
            try container.encode(itemIDs, forKey: .itemIDs)
            try container.encode(refused, forKey: .refused)
        case let .itemDone(itemID):
            try container.encode(Tag.itemDone, forKey: .t)
            try container.encode(itemID, forKey: .itemID)
        case let .stored(itemID):
            try container.encode(Tag.stored, forKey: .t)
            try container.encode(itemID, forKey: .itemID)
        case let .itemFailed(itemID, reason):
            try container.encode(Tag.itemFailed, forKey: .t)
            try container.encode(itemID, forKey: .itemID)
            try container.encode(reason, forKey: .reason)
        case .bye:
            try container.encode(Tag.bye, forKey: .t)
        case .shelfListRequest:
            try container.encode(Tag.shelfListRequest, forKey: .t)
        case let .shelfList(entries):
            try container.encode(Tag.shelfList, forKey: .t)
            try container.encode(entries, forKey: .entries)
        case let .fetchItem(itemID):
            try container.encode(Tag.fetchItem, forKey: .t)
            try container.encode(itemID, forKey: .itemID)
        case let .removeItem(itemID):
            try container.encode(Tag.removeItem, forKey: .t)
            try container.encode(itemID, forKey: .itemID)
        case let .removeAck(itemID):
            try container.encode(Tag.removeAck, forKey: .t)
            try container.encode(itemID, forKey: .itemID)
        case let .failure(code, message):
            try container.encode(Tag.failure, forKey: .t)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
        }
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decoded(from data: Data) throws -> WireMessage {
        try JSONDecoder().decode(WireMessage.self, from: data)
    }
}
