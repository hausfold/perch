import Foundation

/// What the Mac's pairing QR carries, also pasteable as one line for a phone
/// with no camera pointed at the screen (or a simulator with no camera at
/// all). Deliberately NOT an address: the phone finds the Mac over Bonjour by
/// `macID`, so the QR stays valid when the Mac's IP changes mid-pairing.
public struct PairingOffer: Codable, Sendable, Equatable {
    public let version: Int
    public let macID: UUID
    public let macName: String
    /// One-shot secret; the Mac forgets it the moment pairing ends either way.
    public let secret: Data

    public init(macID: UUID, macName: String, secret: Data) {
        version = WireProtocol.version
        self.macID = macID
        self.macName = macName
        self.secret = secret
    }

    private static let prefix = "perch-pair:"

    /// The single line the QR encodes: `perch-pair:` + base64 of the JSON.
    public func encodedString() throws -> String {
        Self.prefix + (try JSONEncoder().encode(self)).base64EncodedString()
    }

    public static func decode(from string: String) -> PairingOffer? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix),
              let data = Data(base64Encoded: String(trimmed.dropFirst(prefix.count))),
              let offer = try? JSONDecoder().decode(PairingOffer.self, from: data),
              offer.version == WireProtocol.version
        else {
            return nil
        }
        return offer
    }
}

/// A phone the Mac has agreed to receive from, or (mirrored) the Mac a phone
/// has agreed to send to. The key is the entire relationship: revoking a
/// device is deleting this record.
public struct PairedPeer: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let deviceKey: Data
    public let pairedAt: Date

    public init(id: UUID, name: String, deviceKey: Data, pairedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.deviceKey = deviceKey
        self.pairedAt = pairedAt
    }
}
