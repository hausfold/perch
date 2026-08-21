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
    private static let service = "com.hausfold.perch.mobile-device"
    private let logger = Logger(subsystem: "com.hausfold.perch", category: "PairedDevices")
    private let lock = NSLock()

    /// Listing is two steps on purpose: the file-based Keychain the Mac app
    /// gets rejects `kSecMatchLimitAll` together with `kSecReturnData` outright
    /// (`errSecParam`), so ask it for the accounts and read each one singly.
    /// Only the file-based Keychain has that limit — moving these queries to
    /// the data-protection one would lift it, and strand every device paired
    /// before the move.
    func all() -> [PairedPeer] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status != errSecItemNotFound {
                logger.error("Keychain list failed: \(status, privacy: .public)")
            }
            return []
        }
        let peers = items
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .compactMap(UUID.init(uuidString:))
            .compactMap(peer(for:))
        // A device the second read can't resolve would drop out of the list
        // silently — the same "no devices paired" lie this method just stopped
        // telling. Count is safe to log; the identity behind it is not.
        if peers.count != items.count {
            logger.error("Keychain list skipped \(items.count - peers.count, privacy: .public) unreadable device(s)")
        }
        return peers.sorted { $0.pairedAt < $1.pairedAt }
    }

    /// Must stay lock-free: `all()` calls this per item, and `lock` is a
    /// non-recursive `NSLock`, so taking it here would deadlock that walk.
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
