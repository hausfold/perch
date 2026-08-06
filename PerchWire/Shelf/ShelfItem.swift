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
}

struct PendingTransfer: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case waitingForSource
        case downloadingFromCloud
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
