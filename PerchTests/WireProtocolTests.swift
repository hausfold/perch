import CryptoKit
import Foundation
import Network
import XCTest

@testable import Perch

final class WireProtocolTests: XCTestCase {
    // MARK: - Framing

    func testControlPayloadRoundtrip() throws {
        let message = WireMessage.offer(
            transferID: UUID(),
            items: [OfferedItem(
                id: UUID(),
                displayName: "photo.jpg",
                contentTypeIdentifier: "public.jpeg",
                kindHint: "image",
                byteCount: 12345,
                sha256: Data(repeating: 7, count: 32)
            )]
        )
        let decoded = try WirePayload.decoded(from: WirePayload.control(message).encoded())
        XCTAssertEqual(decoded, .control(message))
    }

    func testChunkPayloadRoundtrip() throws {
        let itemID = UUID()
        let bytes = Data((0..<1024).map { UInt8($0 % 251) })
        let decoded = try WirePayload.decoded(
            from: WirePayload.chunk(itemID: itemID, offset: 987_654_321, data: bytes).encoded()
        )
        XCTAssertEqual(decoded, .chunk(itemID: itemID, offset: 987_654_321, data: bytes))
    }

    func testOversizedFrameIsRejected() {
        XCTAssertThrowsError(
            try WireFrame.prefixed(Data(count: WireProtocol.maxFrameLength + 1))
        )
    }

    // MARK: - Crypto

    func testFrameCryptorRoundtrip() throws {
        let key = SymmetricKey(size: .bits256)
        var sealer = FrameCryptor(key: key)
        var opener = FrameCryptor(key: key)
        for index in 0..<5 {
            let plaintext = Data("frame \(index)".utf8)
            let opened = try opener.open(try sealer.seal(plaintext))
            XCTAssertEqual(opened, plaintext)
        }
    }

    func testReorderedFramesFailToOpen() throws {
        let key = SymmetricKey(size: .bits256)
        var sealer = FrameCryptor(key: key)
        var opener = FrameCryptor(key: key)
        let first = try sealer.seal(Data("first".utf8))
        let second = try sealer.seal(Data("second".utf8))
        // Delivering the second frame first must fail: ordering is enforced
        // by the nonce counter itself.
        XCTAssertThrowsError(try opener.open(second))
        _ = first
    }

    func testPairingAuthRejectsWrongSecret() {
        let auth = WireCrypto.pairingAuth(
            secret: Data(repeating: 1, count: 32),
            context: "test",
            parts: [Data("a".utf8)]
        )
        XCTAssertFalse(WireCrypto.verifyPairingAuth(
            auth,
            secret: Data(repeating: 2, count: 32),
            context: "test",
            parts: [Data("a".utf8)]
        ))
        XCTAssertTrue(WireCrypto.verifyPairingAuth(
            auth,
            secret: Data(repeating: 1, count: 32),
            context: "test",
            parts: [Data("a".utf8)]
        ))
    }

    func testDeviceKeyAgreementMatches() throws {
        let secret = WireCrypto.randomSecret()
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let mac = Curve25519.KeyAgreement.PrivateKey()
        let phoneKey = try WireCrypto.deviceKey(
            privateKey: phone,
            peerPublicKey: mac.publicKey.rawRepresentation,
            pairingSecret: secret
        )
        let macKey = try WireCrypto.deviceKey(
            privateKey: mac,
            peerPublicKey: phone.publicKey.rawRepresentation,
            pairingSecret: secret
        )
        XCTAssertEqual(
            phoneKey.withUnsafeBytes { Data($0) },
            macKey.withUnsafeBytes { Data($0) }
        )
    }

    func testPairingOfferStringRoundtrip() throws {
        let offer = PairingOffer(
            macID: UUID(),
            macName: "Julien's Mac",
            secret: WireCrypto.randomSecret()
        )
        XCTAssertEqual(PairingOffer.decode(from: try offer.encodedString()), offer)
        XCTAssertNil(PairingOffer.decode(from: "not-a-pairing-code"))
    }
}
