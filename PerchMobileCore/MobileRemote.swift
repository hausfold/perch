import Foundation
import Network

/// The phone's side of the shared shelf: what's on the Mac, pulling one of
/// those things down, taking one off.
///
/// Each call is one bounded connection — dial, ask, hang up. The phone already
/// keeps a Bonjour browser running for presence, so the endpoint is usually
/// known and dialling costs a TCP handshake on the LAN.
enum MobileRemote {
    enum RemoteError: LocalizedError {
        case notPaired
        case macAway(String)

        var errorDescription: String? {
            switch self {
            case .notPaired: "No Mac is paired with this device yet."
            case let .macAway(name): "\(name) isn't on this network right now."
            }
        }
    }

    /// What the Mac's shelf holds right now, newest first.
    static func list(
        pairing: MacPairingStore,
        endpoint: NWEndpoint?,
        discoveryTimeout: Duration = .seconds(3)
    ) async throws -> [RemoteEntry] {
        try await withSession(pairing: pairing, endpoint: endpoint, timeout: discoveryTimeout) {
            try await $0.list().sorted { $0.addedAt > $1.addedAt }
        }
    }

    /// Pulls one item down into the inbox and returns the file, ready to hand
    /// to the share sheet.
    static func fetch(
        _ entry: RemoteEntry,
        pairing: MacPairingStore,
        endpoint: NWEndpoint?,
        discoveryTimeout: Duration = .seconds(4),
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> URL {
        // One directory per item: two fetches of "Photo.jpg" must not fight
        // over the same name, and pruning is then a single removal.
        let directory = MobileConfig.inboxRoot
            .appending(path: entry.id.uuidString, directoryHint: .isDirectory)
        return try await withSession(pairing: pairing, endpoint: endpoint, timeout: discoveryTimeout) {
            try await $0.fetch(entry.id, into: directory, onProgress: onProgress)
        }
    }

    static func remove(
        _ entry: RemoteEntry,
        pairing: MacPairingStore,
        endpoint: NWEndpoint?,
        discoveryTimeout: Duration = .seconds(4)
    ) async throws {
        try await withSession(pairing: pairing, endpoint: endpoint, timeout: discoveryTimeout) {
            try await $0.remove(entry.id)
        }
    }

    /// Fetched files are a hand-off, not storage: once they've been through the
    /// share sheet the phone has no further use for them. A day is long enough
    /// that "share it again" still works, short enough that the container
    /// doesn't quietly become a second copy of the Mac.
    static func pruneInbox(olderThan age: TimeInterval = 24 * 60 * 60) {
        let cutoff = Date().addingTimeInterval(-age)
        let containers = (try? FileManager.default.contentsOfDirectory(
            at: MobileConfig.inboxRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        )) ?? []
        for container in containers {
            let modified = (try? container.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: container)
            }
        }
    }

    // MARK: - Plumbing

    private static func withSession<T>(
        pairing: MacPairingStore,
        endpoint: NWEndpoint?,
        timeout: Duration,
        _ body: (WireRemoteClient) async throws -> T
    ) async throws -> T {
        guard let mac = pairing.pairedMac() else { throw RemoteError.notPaired }
        // A cached endpoint from the live browser is the fast path; falling
        // back to a fresh browse covers the first call after launch.
        var resolved = endpoint
        if resolved == nil {
            resolved = await WireBrowser.waitFor(macID: mac.id, timeout: timeout)
        }
        guard let endpoint = resolved else { throw RemoteError.macAway(mac.name) }
        let identity = MobileConfig.deviceIdentity()
        let client = try await WireRemoteClient.connect(
            to: endpoint,
            deviceID: identity.id,
            deviceKey: mac.deviceKey
        )
        do {
            let result = try await body(client)
            await client.close()
            return result
        } catch {
            await client.close()
            throw error
        }
    }
}
