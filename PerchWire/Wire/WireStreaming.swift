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
    ///
    /// Nothing past the offered length ever reaches the wire: a file that grew
    /// between the digest and the bytes fails here, before the first chunk the
    /// peer would have to reject.
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
            // The digest was taken from these same bytes moments ago, so a chunk
            // running past the promised length means the file grew underfoot.
            // The peer is holding the arrivals to that same length and refuses
            // this frame; sending it would strand every frame after it in the
            // socket, so the file fails here instead.
            guard offset + Int64(data.count) <= item.offered.byteCount else {
                throw WireClientError.fileUnreadable(item.offered.displayName)
            }
            try await connection.send(.chunk(itemID: item.offered.id, offset: offset, data: data))
            offset += Int64(data.count)
            await onProgress(offset, item.offered.byteCount)
        }
        // The mirror case, and the only one the loop cannot see coming: a file
        // that shrank just ends early, leaving the peer waiting on bytes that
        // are never sent.
        guard offset == item.offered.byteCount else {
            throw WireClientError.fileUnreadable(item.offered.displayName)
        }
    }
}
