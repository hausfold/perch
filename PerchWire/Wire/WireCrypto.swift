import CryptoKit
import Foundation

public enum WireCryptoError: LocalizedError {
    case badAuth
    case counterExhausted
    case sealFailed

    public var errorDescription: String? {
        switch self {
        case .badAuth: "The peer failed authentication."
        case .counterExhausted: "The session sent too many frames."
        case .sealFailed: "A frame could not be sealed or opened."
        }
    }
}

/// The static crypto recipe both ends of the wire share.
///
/// Pairing proves possession of the QR secret with HMACs over the handshake
/// transcript, then upgrades it to a long-term per-device key via X25519 so
/// the QR secret itself never needs to be stored anywhere. Sessions derive
/// fresh directional keys from that device key and two nonces, so a recorded
/// session can't be replayed and frame counters never collide.
public enum WireCrypto {
    // MARK: - Pairing

    public static func randomSecret(_ count: Int = 32) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// HMAC binding one side's pairing message to the QR secret and the
    /// transcript so far. `context` keeps the phone's and the Mac's auth
    /// values from being mirror-playable against each other.
    public static func pairingAuth(
        secret: Data,
        context: String,
        parts: [Data]
    ) -> Data {
        var message = Data(context.utf8)
        for part in parts {
            var length = UInt32(part.count).bigEndian
            withUnsafeBytes(of: &length) { message.append(contentsOf: $0) }
            message.append(part)
        }
        let mac = HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: secret)
        )
        return Data(mac)
    }

    public static func verifyPairingAuth(
        _ auth: Data,
        secret: Data,
        context: String,
        parts: [Data]
    ) -> Bool {
        let expected = pairingAuth(secret: secret, context: context, parts: parts)
        guard expected.count == auth.count else { return false }
        // Constant-time comparison; a plain == on Data may short-circuit.
        var difference: UInt8 = 0
        for (a, b) in zip(expected, auth) {
            difference |= a ^ b
        }
        return difference == 0
    }

    /// The long-term key both sides store at the end of a successful pairing.
    public static func deviceKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Data,
        pairingSecret: Data
    ) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: pairingSecret,
            sharedInfo: Data("perch device key v1".utf8),
            outputByteCount: 32
        )
    }

    /// Six digits both screens show during pairing so a user can see they
    /// paired with the machine they meant to.
    public static func confirmationCode(
        pairingSecret: Data,
        phonePublicKey: Data,
        macPublicKey: Data
    ) -> String {
        var transcript = Data("perch sas v1".utf8)
        transcript.append(pairingSecret)
        transcript.append(phonePublicKey)
        transcript.append(macPublicKey)
        let digest = SHA256.hash(data: transcript)
        let value = digest.withUnsafeBytes { raw in
            raw.load(fromByteOffset: 0, as: UInt32.self).bigEndian
        }
        return String(format: "%06d", value % 1_000_000)
    }

    // MARK: - Sessions

    public struct SessionKeys: Sendable {
        public let phoneToMac: SymmetricKey
        public let macToPhone: SymmetricKey
    }

    public static func sessionKeys(
        deviceKey: SymmetricKey,
        phoneNonce: Data,
        macNonce: Data
    ) -> SessionKeys {
        var salt = phoneNonce
        salt.append(macNonce)
        let ikm = deviceKey.withUnsafeBytes { Data($0) }
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: ikm),
                salt: salt,
                info: Data(info.utf8),
                outputByteCount: 32
            )
        }
        return SessionKeys(
            phoneToMac: derive("perch session phone->mac v1"),
            macToPhone: derive("perch session mac->phone v1")
        )
    }
}

/// Seals and opens the frames of one direction of one session.
///
/// Nonces are a strict counter, so ordering is enforced by decryption itself:
/// a dropped, duplicated, or reordered frame fails to open and kills the
/// session. Each direction has its own key, so the two counters never meet.
public struct FrameCryptor: Sendable {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    public init(key: SymmetricKey) {
        self.key = key
    }

    private mutating func nextNonce() throws -> ChaChaPoly.Nonce {
        guard counter != .max else { throw WireCryptoError.counterExhausted }
        var bytes = Data(count: 4)
        var big = counter.bigEndian
        withUnsafeBytes(of: &big) { bytes.append(contentsOf: $0) }
        counter += 1
        return try ChaChaPoly.Nonce(data: bytes)
    }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nextNonce())
        // `combined` includes the nonce; the receiver still recomputes its own
        // counter and rejects a mismatch, so a peer can't pick nonces.
        return box.combined
    }

    public mutating func open(_ ciphertext: Data) throws -> Data {
        let expectedNonce = try nextNonce()
        let box = try ChaChaPoly.SealedBox(combined: ciphertext)
        guard Data(box.nonce) == Data(expectedNonce) else {
            throw WireCryptoError.sealFailed
        }
        return try ChaChaPoly.open(box, using: key)
    }
}
