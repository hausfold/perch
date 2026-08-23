import Foundation
import UniformTypeIdentifiers

struct ShelfItem: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case file
        case folder
        case image
        case link
        case text
    }

    let id: UUID
    let displayName: String
    let relativePath: String
    let kind: Kind
    let contentTypeIdentifier: String?
    let byteCount: Int64?
    let addedAt: Date
    /// A pinned item remains on the shelf after a successful drag-out so it can
    /// be dropped into several destinations in quick succession.
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        displayName: String,
        relativePath: String,
        kind: Kind,
        contentTypeIdentifier: String?,
        byteCount: Int64?,
        addedAt: Date = Date(),
        isPinned: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.relativePath = relativePath
        self.kind = kind
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
        self.addedAt = addedAt
        self.isPinned = isPinned
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case relativePath
        case kind
        case contentTypeIdentifier
        case byteCount
        case addedAt
        case isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        kind = try container.decode(Kind.self, forKey: .kind)
        contentTypeIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .contentTypeIdentifier
        )
        byteCount = try container.decodeIfPresent(Int64.self, forKey: .byteCount)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        // Manifests written before pinning existed have no key; they remain
        // valid and restore as ordinary, unpinned items.
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    var contentType: UTType? {
        contentTypeIdentifier.flatMap(UTType.init)
    }

    func fileURL(inside root: URL) -> URL? {
        let components = (relativePath as NSString).pathComponents
        guard !relativePath.hasPrefix("/"),
              !components.contains(".."),
              !components.isEmpty
        else {
            return nil
        }
        return root.appending(path: relativePath).standardizedFileURL
    }

    /// The same item, pointing at `url` — its identity, pin and arrival time
    /// carried across unchanged.
    ///
    /// Used when a staged file is found under a new name (see
    /// `StagingRepository.resolvedURL(for:)`): the shelf follows the rename
    /// rather than orphaning the tile, so `displayName` follows it too. Returns
    /// nil when nothing moved, so callers can tell "already current" from
    /// "rewrite the manifest".
    ///
    /// Deliberately no `resolvingSymlinksInPath()`: that lstats every component
    /// of a deep Application Support path, and this runs once per shelf item on
    /// the path that opens the panel. `StagingRepository` resolves its root once
    /// at init and only ever hands back URLs built from it, so both sides are
    /// already resolved by construction.
    func restaged(at url: URL, inside root: URL) -> ShelfItem? {
        var rootPath = root.standardizedFileURL.path
        while rootPath.hasSuffix("/") { rootPath.removeLast() }
        let absolute = url.standardizedFileURL.path
        guard absolute.hasPrefix(rootPath + "/") else { return nil }
        let path = String(absolute.dropFirst(rootPath.count + 1))
        guard !path.isEmpty, path != relativePath else { return nil }
        return ShelfItem(
            id: id,
            displayName: url.lastPathComponent,
            relativePath: path,
            // A rename changes neither the bytes nor what they are.
            kind: kind,
            contentTypeIdentifier: contentTypeIdentifier,
            byteCount: byteCount,
            addedAt: addedAt,
            isPinned: isPinned
        )
    }
}

struct PendingTransfer: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case waitingForSource
        /// Waiting on iCloud to bring an evicted file down. iCloud publishes no
        /// percentage an unentitled app can read (see `CloudDownloadWaiter`),
        /// so the honest signal is how long the wait has run — a phase that can
        /// last two minutes must not look like a spinner that will never stop.
        case downloadingFromCloud(elapsedSeconds: Int)
        case copying
    }

    let id: UUID
    let displayName: String
    var phase: Phase
}

struct ShelfManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = currentVersion
    var items: [ShelfItem]
    var updatedAt = Date()
}
