import Foundation
import Security

/// The phone's memory of the Mac it delivers to. One Mac in v1 — the product
/// sentence is "it'll be waiting on your Mac", singular.
///
/// The record lives in the keychain under the App Group access group so the
/// Share extension can seal frames with the same device key the app paired
/// with.
final class MacPairingStore: @unchecked Sendable {
    private static let service = "com.hausfold.perch.mobile-mac"
    private static let account = "paired-mac"

    func pairedMac() -> PairedPeer? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
        ]
        query[kSecAttrAccessGroup as String] = MobileConfig.appGroupID
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else {
            return nil
        }
        return try? JSONDecoder().decode(PairedPeer.self, from: data)
    }

    func store(_ mac: PairedPeer) throws {
        let data = try JSONEncoder().encode(mac)
        var base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        base[kSecAttrAccessGroup as String] = MobileConfig.appGroupID
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        // The extension may fire while the phone is locked-after-restart;
        // AfterFirstUnlock matches how the queue itself is protected.
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

    func unpair() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        query[kSecAttrAccessGroup as String] = MobileConfig.appGroupID
        SecItemDelete(query as CFDictionary)
    }
}
