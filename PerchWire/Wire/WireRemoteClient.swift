import CryptoKit
import Foundation
import Network

/// The phone's browsing half of a session: list what is on the Mac's shelf,
/// pull one item off it, take one off it.
///
/// Always phone-initiated — the Mac never dials a phone, so "shared shelf"
/// means the phone asks, not that the Mac pushes. One instance owns one
/// connection and can answer several requests before `close()`.
public actor WireRemoteClient {
    private let connection: WireConnection

    private init(connection: WireConnection) {
        self.connection = connection
    }

    public static func connect(
        to endpoint: NWEndpoint,
        deviceID: UUID,
        deviceKey: Data
    ) async throws -> WireRemoteClient {
        WireRemoteClient(connection: try await WireSession.open(
            to: endpoint,
            deviceID: deviceID,
            deviceKey: deviceKey
        ))
    }

    /// Says goodbye so the Mac's session ends cleanly rather than as a dropped
    /// connection, then drops the socket.
    public func close() async {
        try? await connection.send(.control(.bye))
        await connection.cancel()
    }

    /// What is on the Mac's shelf right now, in the Mac's own order.
    public func list() async throws -> [RemoteEntry] {
        try await connection.send(.control(.shelfListRequest))
        switch try await connection.receiveMessage() {
        case let .shelfList(entries):
            return entries
        case let .failure(_, message):
            throw WireClientError.peerFailure(message)
        default:
            throw WireClientError.unexpectedReply
        }
    }

    /// Takes an item off the Mac's shelf. The Mac decides what that means for
    /// the bytes; the phone only learns that it worked.
    public func remove(_ itemID: UUID) async throws {
        try await connection.send(.control(.removeItem(itemID: itemID)))
        switch try await connection.receiveMessage() {
        case let .removeAck(acked) where acked == itemID:
            return
        case let .itemFailed(_, reason):
            throw WireClientError.peerFailure(reason)
        case let .failure(_, message):
            throw WireClientError.peerFailure(message)
        default:
            throw WireClientError.unexpectedReply
        }
    }

    /// Pulls one item into `directory` and returns the landed file.
    ///
    /// The bytes are held to the digest the Mac offered before a single one
    /// arrived, and only get their real name once they match — a half-arrived
    /// file is never something the phone can hand to another app.
    public func fetch(
        _ itemID: UUID,
        into directory: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> URL {
        try await connection.send(.control(.fetchItem(itemID: itemID)))

        let offered: OfferedItem
        switch try await connection.receive() {
        case let .control(.offer(_, items)):
            guard let first = items.first, first.id == itemID else {
                throw WireClientError.unexpectedReply
            }
            offered = first
        case let .control(.itemFailed(_, reason)):
            throw WireClientError.peerFailure(reason)
        case let .control(.failure(_, message)):
            throw WireClientError.peerFailure(message)
        default:
            throw WireClientError.unexpectedReply
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appending(path: ".\(itemID.uuidString).partial")
        try? FileManager.default.removeItem(at: partial)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: partial.path) else {
            throw WireClientError.fileUnreadable(offered.displayName)
        }

        do {
            var digest = SHA256()
            var received: Int64 = 0
            receiveLoop: while true {
                switch try await connection.receive() {
                case let .chunk(id, offset, data):
                    // Offsets are strictly sequential and the total is known
                    // up front; anything else is a peer bug, not a retry.
                    guard id == itemID,
                          offset == received,
                          received + Int64(data.count) <= offered.byteCount
                    else {
                        throw WireClientError.peerFailure("The transfer stream went out of order.")
                    }
                    try handle.write(contentsOf: data)
                    digest.update(data: data)
                    received += Int64(data.count)
                    onProgress?(received, offered.byteCount)
                case .control(.itemDone):
                    break receiveLoop
                case let .control(.itemFailed(_, reason)):
                    throw WireClientError.peerFailure(reason)
                case let .control(.failure(_, message)):
                    throw WireClientError.peerFailure(message)
                default:
                    throw WireClientError.unexpectedReply
                }
            }
            try handle.close()
            guard received == offered.byteCount,
                  Data(digest.finalize()) == offered.sha256
            else {
                throw WireClientError.peerFailure("\(offered.displayName) arrived corrupted.")
            }
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: partial)
            throw error
        }

        let destination = directory.appending(
            path: StagingRepository.safeFilename(offered.displayName)
        )
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }
}
