import Foundation
import OSLog
import Security

/// The Mac's memory of which phones may deliver to its shelf.
///
/// Each paired device is one Keychain generic-password item: the device key
/// IS the relationship, so it lives where keys live, not in a JSON file in
/// the container. Revoking a device deletes its item; there is nothing else
/// to clean up anywhere.
///
/// **This is the file-based Keychain, and it has to stay that way.** The
/// data-protection Keychain (`kSecUseDataProtectionKeychain`) would let
/// `all()` ask for everything and its data in one query, but it refuses every
/// call from a process it cannot attribute to a Keychain access group —
/// `errSecMissingEntitlement`, -34018. Naming one needs a
/// `keychain-access-groups` entitlement, which is provisioning-profile-gated:
/// perch ships Developer-ID-signed with no profile (`.github/workflows/
/// release.yml`), and such a binary carrying that entitlement is SIGKILLed at
/// exec. The App Group perch already has is **not** accepted as a substitute;
/// measured, both refused with -34018. So the two-step read below is not a
/// workaround to be tidied away later — it is the shape this Keychain
/// requires. Measurements are in `PairedDeviceStoreTests`.
final class PairedDeviceStore: @unchecked Sendable {
    static let defaultService = "com.hausfold.perch.mobile-device"
    /// Overridden only by tests, so a round trip never touches the real
    /// pairings on the machine running them.
    private let service: String
    private let logger = Logger(subsystem: "com.hausfold.perch", category: "PairedDevices")
    private let lock = NSLock()

    init(service: String = PairedDeviceStore.defaultService) {
        self.service = service
    }

    /// Listing is two steps on purpose: the file-based Keychain rejects
    /// `kSecMatchLimitAll` together with `kSecReturnData` outright
    /// (`errSecParam`, -50), so ask it for the accounts and read each one
    /// singly. See the type comment for why moving off that Keychain is not
    /// available to perch.
    func all() -> [PairedPeer] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(Query.listAccounts(service: service) as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status == errSecItemNotFound {
                // Not an error, and not the same thing as a failed read — #12
                // presented as an empty list and the log could not tell the two
                // apart. Count is safe to log; the identity behind it is not.
                logger.info("Keychain list: no paired devices")
            } else {
                logger.error("Keychain list failed: \(status, privacy: .public)")
            }
            return []
        }
        let peers = items
            .compactMap { $0[kSecAttrAccount as String] as? String }
            .compactMap(UUID.init(uuidString:))
            .compactMap(peer(for:))
        // A device the second read can't resolve would drop out of the list
        // silently — the same "no devices paired" lie this method exists to
        // stop telling.
        if peers.count != items.count {
            logger.error("Keychain list skipped \(items.count - peers.count, privacy: .public) unreadable device(s)")
        } else {
            logger.info("Keychain list: \(peers.count, privacy: .public) paired device(s)")
        }
        return peers.sorted { $0.pairedAt < $1.pairedAt }
    }

    /// Must stay lock-free: `all()` calls this per item, and `lock` is a
    /// non-recursive `NSLock`, so taking it here would deadlock that walk.
    func peer(for deviceID: UUID) -> PairedPeer? {
        var result: CFTypeRef?
        guard SecItemCopyMatching(Query.read(service: service, account: deviceID) as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else {
            return nil
        }
        return try? JSONDecoder().decode(PairedPeer.self, from: data)
    }

    func store(_ peer: PairedPeer) throws {
        try lock.withLock {
            let data = try JSONEncoder().encode(peer)
            // Re-pairing the same phone replaces its record.
            SecItemDelete(Query.item(service: service, account: peer.id) as CFDictionary)
            let status = SecItemAdd(
                Query.add(service: service, account: peer.id, data: data) as CFDictionary,
                nil
            )
            guard status == errSecSuccess else {
                logger.error("Keychain add failed: \(status, privacy: .public)")
                throw NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(status),
                    userInfo: [NSLocalizedDescriptionKey: "The pairing could not be saved to the keychain."]
                )
            }
        }
    }

    func revoke(_ deviceID: UUID) {
        SecItemDelete(Query.item(service: service, account: deviceID) as CFDictionary)
    }

    /// The four queries, built in one place and nowhere else.
    ///
    /// A read and a write disagreeing about which Keychain, or about which
    /// attributes scope an item, presents as a *wrong answer* rather than as an
    /// error — #12's shape. `PairedDeviceStoreTests` pins all four.
    enum Query {
        static func base(service: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ]
        }

        /// Scopes a read or a delete to exactly one device.
        static func item(service: String, account: UUID) -> [String: Any] {
            var query = base(service: service)
            query[kSecAttrAccount as String] = account.uuidString
            return query
        }

        static func read(service: String, account: UUID) -> [String: Any] {
            var query = item(service: service, account: account)
            query[kSecReturnData as String] = true
            return query
        }

        /// Step one of the listing: accounts only. Adding `kSecReturnData` here
        /// is the -50 that #82 found — measured again in the tests, so nobody
        /// "simplifies" the two steps back into one.
        static func listAccounts(service: String) -> [String: Any] {
            var query = base(service: service)
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            query[kSecReturnAttributes as String] = true
            return query
        }

        static func add(service: String, account: UUID, data: Data) -> [String: Any] {
            var query = item(service: service, account: account)
            query[kSecValueData as String] = data
            // Delivery has to work while the Mac is logged out but awake, and
            // never before the disk is unlocked once.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return query
        }
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
