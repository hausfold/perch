import Foundation
import Security
import UIKit

/// Shared ground between the iOS app and its Share extension: the App Group
/// container, this phone's wire identity, and where the phone-side shelf
/// lives. Both processes read and write the same places, which is the whole
/// reason these paths live in the group container and not in either sandbox.
enum MobileConfig {
    static let appGroupID = "group.com.nebelhaus.perch"

    static var groupContainer: URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            // Without the App Group entitlement nothing about the product
            // works; failing loudly beats silently staging into a sandbox the
            // other process can't see.
            fatalError("The \(appGroupID) App Group is missing from the build.")
        }
        return url
    }

    /// The phone's shelf: the same staging layout as the Mac's, one UUID
    /// container per item, a manifest beside them.
    static var shelfRoot: URL {
        groupContainer.appending(path: "MobileShelf", directoryHint: .isDirectory)
    }

    /// Where items pulled off the Mac land. Deliberately NOT the shelf root:
    /// anything in there is an outbox entry and would be delivered straight
    /// back to the Mac it just came from.
    static var inboxRoot: URL {
        groupContainer.appending(path: "MacInbox", directoryHint: .isDirectory)
    }

    static var groupDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    /// This phone's stable wire identity, minted on first use.
    ///
    /// It lives in the keychain — the same store as the pairing record — on
    /// purpose. A reinstall wipes the group container but keeps the keychain,
    /// so splitting the two produced a phone that still held a device key
    /// while presenting a brand-new deviceID: "paired" on screen, refused by
    /// the Mac. Identity and pairing survive together or die together.
    static func deviceIdentity() -> (id: UUID, name: String) {
        let service = "com.nebelhaus.perch.mobile-identity"
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "device-id",
            kSecReturnData as String: true,
        ]
        query[kSecAttrAccessGroup as String] = appGroupID
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let stored = UUID(uuidString: String(decoding: data, as: UTF8.self)) {
            return (stored, UIDevice.current.name)
        }
        let id = UUID()
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "device-id",
            kSecValueData as String: Data(id.uuidString.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        add[kSecAttrAccessGroup as String] = appGroupID
        SecItemAdd(add as CFDictionary, nil)
        return (id, UIDevice.current.name)
    }
}
