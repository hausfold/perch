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
    /// What perch is writing into watched folders itself, so a drag-out is
    /// adopted rather than shelved straight back. See `ExportLedger`.
    private let exportLedger: ExportLedger
    private var watchers: [UUID: FolderWatcher] = [:]
    private var resolvedPaths: [UUID: String] = [:]
    /// Where each configured folder was last seen, INCLUDING the ones whose
    /// watcher has since fallen over. `resolvedPaths` answers "what is being
    /// watched right now" and is cleared the moment a folder goes unavailable;
    /// this answers "what is configured", which is the question the dedupe
    /// below has to ask. Both are in-memory only — the bookmark stays the sole
    /// persisted trace of a folder. Dropped on `removeFolder`, so a folder the
    /// person took out is genuinely gone.
    private var lastKnownPaths: [UUID: String] = [:]
    /// Which incarnation of each folder's watcher is the current one. A
    /// watcher that has been stopped and replaced — a bookmark that stopped
    /// resolving and came back — can still have a stream position in flight
    /// to the main actor, and "some watcher is installed" does not prove it
    /// is *this* one. Letting a stale report through would rewind the
    /// persisted position under its successor.
    private var watcherGenerations: [UUID: UUID] = [:]
    private let logger = Logger(subsystem: "com.hausfold.perch", category: "WatchedFolders")

    init(
        shelf: ShelfStore,
        folders: WatchedFolderStore,
        exportLedger: ExportLedger = .shared
    ) {
        self.shelf = shelf
        folderStore = folders
        self.exportLedger = exportLedger
    }

    func start() {
        // An export writes the last byte itself, so the destination folder can
        // fall quiet with nothing left to trigger a scan. Nudge the watcher
        // that owns it instead of waiting for one.
        exportLedger.onWritten = { [weak self] url in
            Task { @MainActor in
                self?.rescanFolder(containing: url)
            }
        }
        for folder in folderStore.folders {
            startWatching(folder, seedExisting: false)
        }
        refreshRows()
    }

    func stop() {
        exportLedger.onWritten = nil
        for watcher in watchers.values {
            watcher.stop()
        }
        watchers.removeAll()
        watcherGenerations.removeAll()
    }

    /// A file just written into one of the watched folders — look again there.
    /// Only the folder itself: a watcher lists its own directory and nothing
    /// below it, so a drop into a subfolder was never going to be imported.
    private func rescanFolder(containing url: URL) {
        let parent = url.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard let folderID = resolvedPaths.first(where: { $0.value == parent })?.key else {
            return
        }
        watchers[folderID]?.rescan()
    }

    /// The id of the folder now being watched — the existing one when this is
    /// a folder perch already has, so adding one twice is an adoption rather
    /// than a second watcher.
    @discardableResult
    func addFolder(at url: URL) -> UUID? {
        // Compare through symlinks, or the same directory picked via an alias
        // would get a second watcher — and every arrival two tiles.
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        if let existing = resolvedPaths.first(where: { $0.value == canonical })?.key {
            return existing
        }
        // Configured but not currently watched — a bookmark that stopped
        // resolving (`markUnavailable`), or one still resolving at launch.
        // Adding "again" is a repair, not a second folder: without this the
        // store, which does not dedupe, would grow a twin entry and every
        // arrival would land twice. The panel just handed us access, so a
        // fresh bookmark is exactly what the stale entry needs.
        if let stale = lastKnownPaths.first(where: { $0.value == canonical })?.key,
           folderStore.folders.contains(where: { $0.id == stale }) {
            if let refreshed = try? folderStore.bookmarking.make(url) {
                folderStore.updateBookmark(stale, to: refreshed)
            }
            if let folder = folderStore.folders.first(where: { $0.id == stale }) {
                startWatching(folder, seedExisting: true)
            }
            return stale
        }
        do {
            let folder = try folderStore.add(folderAt: url)
            resolvedPaths[folder.id] = canonical
            lastKnownPaths[folder.id] = canonical
            startWatching(folder, seedExisting: true)
            refreshRows()
            return folder.id
        } catch {
            shelf.latestError = "Perch could not keep access to that folder: \(error.localizedDescription)"
            return nil
        }
    }

    /// Is one of the configured folders this path? The path must already be
    /// canonical — `standardizedFileURL.resolvingSymlinksInPath()`, the same
    /// form `addFolder` dedupes on, so an alias, a symlinked path and the
    /// folder itself all answer as one folder.
    ///
    /// Canonicalising is the CALLER's job precisely because it is a filesystem
    /// call: the one caller asks from a SwiftUI `body`, where doing it here
    /// would put a syscall on the main actor on every render — and stall it
    /// outright on an unmounted volume. It canonicalises once, off main, in the
    /// same task that reads the folder.
    ///
    /// Configured, not "currently being watched": a folder whose bookmark has
    /// stopped resolving is still one of yours (it is the orange row in
    /// Settings), and a caller asking "is this folder already in the list"
    /// must not be told no and go add it twice. False during the first moments
    /// after launch, before any bookmark has resolved.
    func watches(canonicalPath: String) -> Bool {
        lastKnownPaths.values.contains(canonicalPath)
    }

    func removeFolder(_ id: UUID) {
        watchers[id]?.stop()
        watchers[id] = nil
        watcherGenerations[id] = nil
        resolvedPaths[id] = nil
        lastKnownPaths[id] = nil
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
        let generation = UUID()
        let watcher = FolderWatcher(
            folderID: folderID,
            folderURL: url,
            ledger: folder.importedTokens,
            sinceEventID: folder.lastEventID,
            exportLedger: exportLedger,
            onImport: { [weak self] fileURL, token in
                Task { @MainActor in
                    guard let self, self.watchers[folderID] != nil else { return }
                    // Ledgered on success, never on attempt. Recording the
                    // attempt made one transient staging failure permanent:
                    // the file was marked imported, so no later event ever
                    // looked at it again.
                    self.shelf.importFileURLs([fileURL]) { [weak self] _, landed in
                        guard let self else { return }
                        if landed {
                            self.folderStore.markImported(token, for: folderID)
                        } else {
                            self.logger.error("A watched arrival failed to stage; it will be retried")
                            self.watchers[folderID]?.forgetImport(token)
                        }
                    }
                }
            },
            onAdopt: { [weak self] token in
                Task { @MainActor in
                    guard let self, self.watchers[folderID] != nil else { return }
                    // Nothing to stage — the bytes are the ones perch just
                    // wrote out of the shelf. Persisting the token is what
                    // stops a later scan treating it as an arrival once the
                    // in-memory claim is gone.
                    self.folderStore.markImported(token, for: folderID)
                }
            },
            onLedgerReplaced: { [weak self] tokens in
                Task { @MainActor in
                    self?.folderStore.setTokens(tokens, for: folderID)
                }
            },
            onEventID: { [weak self] eventID in
                Task { @MainActor in
                    guard let self, self.watcherGenerations[folderID] == generation else { return }
                    self.folderStore.setLastEventID(eventID, for: folderID)
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
        watcherGenerations[folderID] = generation
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        resolvedPaths[folderID] = canonical
        lastKnownPaths[folderID] = canonical
        refreshRows()
        watcher.start(seedExisting: seedExisting)
    }

    private func markUnavailable(_ id: UUID) {
        watchers[id]?.stop()
        watchers[id] = nil
        watcherGenerations[id] = nil
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
