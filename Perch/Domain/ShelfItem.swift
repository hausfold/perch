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

    init(
        id: UUID = UUID(),
        displayName: String,
        relativePath: String,
        kind: Kind,
        contentTypeIdentifier: String?,
        byteCount: Int64?,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.relativePath = relativePath
        self.kind = kind
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
        self.addedAt = addedAt
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
