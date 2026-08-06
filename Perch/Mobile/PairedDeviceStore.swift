import Foundation
import OSLog
import Security

/// The Mac's memory of which phones may deliver to its shelf.
///
/// Each paired device is one Keychain generic-password item: the device key
/// IS the relationship, so it lives where keys live, not in a JSON file in
/// the container. Revoking a device deletes its item; there is nothing else
/// to clean up anywhere.
final class PairedDeviceStore: @unchecked Sendable {
    private static let service = "com.nebelhaus.perch.mobile-device"
    private let logger = Logger(subsystem: "com.nebelhaus.perch", category: "PairedDevices")
    private let lock = NSLock()

    func all() -> [PairedPeer] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let blobs = result as? [Data] else {
            if status != errSecItemNotFound {
                logger.error("Keychain list failed: \(status, privacy: .public)")
            }
            return []
        }
        return blobs
            .compactMap { try? JSONDecoder().decode(PairedPeer.self, from: $0) }
            .sorted { $0.pairedAt < $1.pairedAt }
    }

    func peer(for deviceID: UUID) -> PairedPeer? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: deviceID.uuidString,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else {
            return nil
        }
        return try? JSONDecoder().decode(PairedPeer.self, from: data)
    }

    func store(_ peer: PairedPeer) throws {
        try lock.withLock {
            let data = try JSONEncoder().encode(peer)
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: peer.id.uuidString,
            ]
            // Re-pairing the same phone replaces its record.
            SecItemDelete(base as CFDictionary)
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(status),
                    userInfo: [NSLocalizedDescriptionKey: "The pairing could not be saved to the keychain."]
                )
            }
        }
    }

    func revoke(_ deviceID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: deviceID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// This Mac's stable identity on the wire: a UUID minted once and the
/// user-visible computer name. The UUID is what phones pair against, so it
/// must survive renames — hence not derived from the name.
enum MacWireIdentity {
    private static let key = "mobileMacID"

    static func current() -> MacIdentity {
        let defaults = UserDefaults.standard
        let id: UUID
        if let stored = defaults.string(forKey: key), let parsed = UUID(uuidString: stored) {
            id = parsed
        } else {
            id = UUID()
            defaults.set(id.uuidString, forKey: key)
        }
        let name = Host.current().localizedName ?? "Mac"
        return MacIdentity(id: id, name: name)
    }
}
