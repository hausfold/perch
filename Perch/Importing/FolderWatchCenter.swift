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
        // Compare through symlinks, or the same directory picked via an alias
        // would get a second watcher — and every arrival two tiles.
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard !resolvedPaths.values.contains(canonical) else { return }
        do {
            let folder = try folderStore.add(folderAt: url)
            resolvedPaths[folder.id] = canonical
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
        let bookmarking = folderStore.bookmarking
        let bookmark = folder.bookmark
        let folderID = folder.id
        // Resolving a bookmark can block while the system tries to reach an
        // unmounted volume, and this is called from `AppRuntime.start()` —
        // so resolution runs detached, never on the main actor.
        Task.detached(priority: .utility) { [weak self] in
            guard let resolved = try? bookmarking.resolve(bookmark) else {
                await MainActor.run { [weak self] in
                    // No path in the log — the bookmark is the only place it lives.
                    self?.logger.error("A watched folder's bookmark no longer resolves")
                    self?.markUnavailable(folderID)
                }
                return
            }
            var refreshed: Data?
            if resolved.isStale {
                // Minting an app-scoped bookmark needs the resource
                // accessible, so scope the URL around the remint.
                let scoped = resolved.url.startAccessingSecurityScopedResource()
                refreshed = try? bookmarking.make(resolved.url)
                if scoped {
                    resolved.url.stopAccessingSecurityScopedResource()
                }
            }
            await MainActor.run { [weak self] in
                self?.attachWatcher(
                    folderID: folderID,
                    url: resolved.url,
                    refreshedBookmark: refreshed,
                    seedExisting: seedExisting
                )
            }
        }
    }

    private func attachWatcher(
        folderID: UUID,
        url: URL,
        refreshedBookmark: Data?,
        seedExisting: Bool
    ) {
        // The folder may have been removed (or re-added) while resolving.
        guard watchers[folderID] == nil,
              let folder = folderStore.folders.first(where: { $0.id == folderID })
        else {
            return
        }
        if let refreshedBookmark {
            folderStore.updateBookmark(folderID, to: refreshedBookmark)
        }
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
            },
            onUnavailable: { [weak self] in
                Task { @MainActor in
                    self?.logger.error("A watched folder could not be opened")
                    self?.markUnavailable(folderID)
                }
            }
        )
        watchers[folderID] = watcher
        resolvedPaths[folderID] = url.standardizedFileURL.resolvingSymlinksInPath().path
        refreshRows()
        watcher.start(seedExisting: seedExisting)
    }

    private func markUnavailable(_ id: UUID) {
        watchers[id]?.stop()
        watchers[id] = nil
        resolvedPaths[id] = nil
        refreshRows()
    }

    private func refreshRows() {
        rows = folderStore.folders.map { folder in
            Row(id: folder.id, displayPath: resolvedPaths[folder.id].map(Self.abbreviate))
        }
    }

    /// `~`-abbreviate against the real home — inside the sandbox,
    /// `NSHomeDirectory()` is the container, not the user's home, which is why
    /// this goes through `RiceFiles.home` (the passwd lookup).
    private static func abbreviate(_ path: String) -> String {
        let home = RiceFiles.home.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
