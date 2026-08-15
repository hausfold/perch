import Foundation
import OSLog

/// One folder the user asked perch to watch. The bookmark is the persisted
/// panel grant; the tokens are the hashed identities of files already shelved
/// from it (see `FolderWatchRules.identityToken` — no name or path in them).
struct WatchedFolder: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var bookmark: Data
    var importedTokens: Set<String>
}

/// How folder grants are minted and resolved. Injected so tests can use plain
/// bookmarks: app-scoped security bookmarks need the sandbox and the
/// `files.bookmarks.app-scope` entitlement, which the unsigned test host does
/// not carry.
struct FolderBookmarking: Sendable {
    var make: @Sendable (URL) throws -> Data
    var resolve: @Sendable (Data) throws -> (url: URL, isStale: Bool)

    static let securityScoped = FolderBookmarking(
        make: { url in
            try url.bookmarkData(options: [.withSecurityScope])
        },
        resolve: { data in
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return (url, stale)
        }
    )

    static let plain = FolderBookmarking(
        make: { url in
            try url.bookmarkData()
        },
        resolve: { data in
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return (url, stale)
        }
    )
}

/// The watched-folder configuration: bookmarks in, per-folder import ledgers
/// alongside. Persisted as one JSON file in the app container — deliberately
/// separate from the shelf manifest, which never learns anything about
/// sources.
@MainActor
final class WatchedFolderStore: ObservableObject {
    @Published private(set) var folders: [WatchedFolder] = []

    let bookmarking: FolderBookmarking

    private let fileURL: URL?
    private let logger = Logger(subsystem: "com.hausfold.perch", category: "WatchedFolders")
    /// Config writes happen here, in order, off the main actor — an arrival
    /// burst into a watched Downloads marks one import per file, and the
    /// shelf must not hitch on the disk for it.
    private let writeQueue = DispatchQueue(
        label: "com.hausfold.perch.watchedfolders.persist",
        qos: .utility
    )

    init(fileURL: URL? = nil, bookmarking: FolderBookmarking = .securityScoped) {
        self.bookmarking = bookmarking
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    func add(folderAt url: URL) throws -> WatchedFolder {
        let folder = WatchedFolder(
            id: UUID(),
            bookmark: try bookmarking.make(url),
            importedTokens: []
        )
        folders.append(folder)
        persist()
        return folder
    }

    func remove(_ id: UUID) {
        folders.removeAll { $0.id == id }
        persist()
    }

    /// A resolution came back stale — keep the refreshed grant so the next
    /// launch does not depend on the old one still resolving.
    func updateBookmark(_ id: UUID, to data: Data) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].bookmark = data
        persist()
    }

    /// Seeding and launch pruning replace the ledger wholesale.
    func setTokens(_ tokens: Set<String>, for id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }),
              folders[index].importedTokens != tokens
        else {
            return
        }
        folders[index].importedTokens = tokens
        persist()
    }

    /// An arrival was handed to import — remembered now, at most once, so a
    /// staging failure surfaces once instead of retrying on every event.
    func markImported(_ token: String, for id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].importedTokens.insert(token)
        persist()
    }

    private func load() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL)
        else {
            return
        }
        do {
            folders = try JSONDecoder().decode([WatchedFolder].self, from: data)
        } catch {
            // A config that cannot be read is a config that starts over; the
            // grants it held can be granted again in one panel each.
            logger.error("Could not decode watched-folder config: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        guard let fileURL else { return }
        let snapshot = folders
        writeQueue.async { [logger] in
            do {
                let data = try JSONEncoder().encode(snapshot)
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                logger.error("Could not persist watched-folder config: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Test hook: block until every queued config write has hit the disk.
    func flushPendingWrites() {
        writeQueue.sync {}
    }

    private static func defaultFileURL() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        return support
            .appending(path: "Perch", directoryHint: .isDirectory)
            .appending(path: "watched-folders.json")
    }
}
