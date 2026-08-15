import Foundation
import OSLog

/// Owns one `FolderWatcher` per configured folder and bridges the two stores:
/// resolved grants and ledger updates land in `WatchedFolderStore`, ready
/// arrivals land in `ShelfStore.importFileURLs` — the same door a drop uses,
/// so a watched file gets the identical pending tile, staging, and commit.
@MainActor
final class FolderWatchCenter: ObservableObject {
    /// What Settings shows per folder: where it points, or nil when the
    /// bookmark no longer resolves (folder deleted, volume gone).
    struct Row: Identifiable, Equatable {
        let id: UUID
        let displayPath: String?
    }

    @Published private(set) var rows: [Row] = []

    private let shelf: ShelfStore
    private let folderStore: WatchedFolderStore
    private var watchers: [UUID: FolderWatcher] = [:]
    private var resolvedPaths: [UUID: String] = [:]
    private let logger = Logger(subsystem: "com.hausfold.perch", category: "WatchedFolders")

    init(shelf: ShelfStore, folders: WatchedFolderStore) {
        self.shelf = shelf
        folderStore = folders
    }

    func start() {
        for folder in folderStore.folders {
            startWatching(folder, seedExisting: false)
        }
        refreshRows()
    }

    func stop() {
        for watcher in watchers.values {
            watcher.stop()
        }
        watchers.removeAll()
    }

    func addFolder(at url: URL) {
        let standardized = url.standardizedFileURL.path
        guard !resolvedPaths.values.contains(standardized) else { return }
        do {
            let folder = try folderStore.add(folderAt: url)
            startWatching(folder, seedExisting: true)
            refreshRows()
        } catch {
            shelf.latestError = "Perch could not keep access to that folder: \(error.localizedDescription)"
        }
    }

    func removeFolder(_ id: UUID) {
        watchers[id]?.stop()
        watchers[id] = nil
        resolvedPaths[id] = nil
        folderStore.remove(id)
        refreshRows()
    }

    private func startWatching(_ folder: WatchedFolder, seedExisting: Bool) {
        let url: URL
        do {
            let resolved = try folderStore.bookmarking.resolve(folder.bookmark)
            url = resolved.url
            if resolved.isStale, let refreshed = try? folderStore.bookmarking.make(url) {
                folderStore.updateBookmark(folder.id, to: refreshed)
            }
        } catch {
            // No path in the log — the bookmark is the only place it lives.
            logger.error("A watched folder's bookmark no longer resolves")
            return
        }

        let folderID = folder.id
        let watcher = FolderWatcher(
            folderID: folderID,
            folderURL: url,
            ledger: folder.importedTokens,
            onImport: { [weak self] fileURL, token in
                Task { @MainActor in
                    guard let self, self.watchers[folderID] != nil else { return }
                    self.folderStore.markImported(token, for: folderID)
                    self.shelf.importFileURLs([fileURL])
                }
            },
            onLedgerReplaced: { [weak self] tokens in
                Task { @MainActor in
                    self?.folderStore.setTokens(tokens, for: folderID)
                }
            }
        )
        guard watcher.start(seedExisting: seedExisting) else {
            logger.error("A watched folder could not be opened")
            return
        }
        watchers[folderID] = watcher
        resolvedPaths[folderID] = url.standardizedFileURL.path
    }

    private func refreshRows() {
        rows = folderStore.folders.map { folder in
            Row(id: folder.id, displayPath: resolvedPaths[folder.id].map(Self.abbreviate))
        }
    }

    /// `~`-abbreviate against the real home — inside the sandbox,
    /// `NSHomeDirectory()` is the container, not the user's home.
    private static func abbreviate(_ path: String) -> String {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else {
            return path
        }
        let home = String(cString: dir)
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
