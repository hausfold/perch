import Foundation

public enum WireFrameError: LocalizedError {
    case oversizedFrame(Int)
    case truncated
    case unknownPayloadType(UInt8)

    public var errorDescription: String? {
        switch self {
        case let .oversizedFrame(count):
            "The peer sent a \(count)-byte frame, which is over the protocol limit."
        case .truncated:
            "The peer sent a truncated frame."
        case let .unknownPayloadType(type):
            "The peer sent an unknown payload type (\(type))."
        }
    }
}

/// What one sealed frame carries: either a JSON control message or a run of
/// file bytes. The one-byte discriminator keeps file chunks off the JSON
/// encoder — a photo doesn't survive base64 twice.
public enum WirePayload: Sendable, Equatable {
    case control(WireMessage)
    case chunk(itemID: UUID, offset: Int64, data: Data)

    private static let controlTag: UInt8 = 0x01
    private static let chunkTag: UInt8 = 0x02

    public func encoded() throws -> Data {
        switch self {
        case let .control(message):
            var data = Data([Self.controlTag])
            data.append(try message.encoded())
            return data
        case let .chunk(itemID, offset, data: bytes):
            var data = Data([Self.chunkTag])
            data.append(contentsOf: withUnsafeBytes(of: itemID.uuid) { Array($0) })
            var big = UInt64(bitPattern: offset).bigEndian
            withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
            data.append(bytes)
            return data
        }
    }

    public static func decoded(from data: Data) throws -> WirePayload {
        guard let tag = data.first else { throw WireFrameError.truncated }
        let body = data.dropFirst()
        switch tag {
        case controlTag:
            return .control(try WireMessage.decoded(from: Data(body)))
        case chunkTag:
            guard body.count >= 24 else { throw WireFrameError.truncated }
            let idBytes = [UInt8](body.prefix(16))
            let uuid = UUID(uuid: (
                idBytes[0], idBytes[1], idBytes[2], idBytes[3],
                idBytes[4], idBytes[5], idBytes[6], idBytes[7],
                idBytes[8], idBytes[9], idBytes[10], idBytes[11],
                idBytes[12], idBytes[13], idBytes[14], idBytes[15]
            ))
            let offsetBytes = body.dropFirst(16).prefix(8)
            var raw: UInt64 = 0
            for byte in offsetBytes {
                raw = raw << 8 | UInt64(byte)
            }
            return .chunk(
                itemID: uuid,
                offset: Int64(bitPattern: raw),
                data: Data(body.dropFirst(24))
            )
        default:
            throw WireFrameError.unknownPayloadType(tag)
        }
    }
}

/// The length prefix every frame travels behind.
public enum WireFrame {
    public static func prefixed(_ payload: Data) throws -> Data {
        guard payload.count <= WireProtocol.maxFrameLength else {
            throw WireFrameError.oversizedFrame(payload.count)
        }
        var data = Data(capacity: payload.count + 4)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    public static func length(fromPrefix data: Data) throws -> Int {
        guard data.count >= 4 else { throw WireFrameError.truncated }
        var value: UInt32 = 0
        for byte in data.prefix(4) {
            value = value << 8 | UInt32(byte)
        }
        let length = Int(value)
        guard length <= WireProtocol.maxFrameLength else {
            throw WireFrameError.oversizedFrame(length)
        }
        return length
    }
}
