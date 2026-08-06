import CryptoKit
import Foundation

/// Turning a staged file into an offer, and an offer into frames.
///
/// Both directions need exactly this: the phone delivering to the Mac, and the
/// Mac serving a fetch back to a phone. Keeping it in one place is what makes
/// "the bytes are verified end to end" a single fact rather than two
/// implementations that have to agree.
public enum WireStreaming {
    /// Describes a staged file well enough for the far side to admit it and to
    /// hold the arriving bytes to a digest.
    ///
    /// Reads the whole file to hash it — never call this on the main actor.
    public static func offer(
        id: UUID,
        displayName: String,
        contentTypeIdentifier: String?,
        kindHint: String,
        fileURL: URL
    ) throws -> OutgoingItem {
        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
            throw WireClientError.fileUnreadable(displayName)
        }
        defer { try? handle.close() }
        var digest = SHA256()
        var byteCount: Int64 = 0
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            digest.update(data: data)
            byteCount += Int64(data.count)
        }
        return OutgoingItem(
            offered: OfferedItem(
                id: id,
                displayName: displayName,
                contentTypeIdentifier: contentTypeIdentifier,
                kindHint: kindHint,
                byteCount: byteCount,
                sha256: Data(digest.finalize())
            ),
            fileURL: fileURL
        )
    }

    /// Streams the file as sequential chunk frames. The caller has already told
    /// the peer what is coming and closes the item afterwards.
    public static func send(
        _ item: OutgoingItem,
        over connection: WireConnection,
        onProgress: (Int64, Int64) async -> Void = { _, _ in }
    ) async throws {
        guard let handle = FileHandle(forReadingAtPath: item.fileURL.path) else {
            throw WireClientError.fileUnreadable(item.offered.displayName)
        }
        defer { try? handle.close() }
        var offset: Int64 = 0
        while true {
            guard let data = try handle.read(upToCount: WireProtocol.chunkSize),
                  !data.isEmpty
            else {
                break
            }
            try await connection.send(.chunk(itemID: item.offered.id, offset: offset, data: data))
            offset += Int64(data.count)
            await onProgress(offset, item.offered.byteCount)
        }
        // The digest was taken from these same bytes moments ago; a different
        // length now means the file changed underfoot and the peer would only
        // find out via a digest mismatch after transferring all of it.
        guard offset == item.offered.byteCount else {
            throw WireClientError.fileUnreadable(item.offered.displayName)
        }
    }
}
