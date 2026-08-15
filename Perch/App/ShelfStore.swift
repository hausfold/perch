import AppKit
import Foundation
import OSLog
import UniformTypeIdentifiers

@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var pendingTransfers: [PendingTransfer] = []
    @Published var latestError: String?

    let repository: StagingRepository

    private let pipeline: TransferPipeline
    private let settings: AppSettings
    private let logger = Logger(subsystem: "com.hausfold.perch", category: "Shelf")
    // The live `qlmanage -p` preview, if any, so a new double-click can replace
    // it instead of stacking another window on top.
    private var quickLookProcess: Process?
    // Items taken off the shelf by an accepted drop but not yet accounted for,
    // with the slot each came from so a refused one lands back in place. Their
    // staged bytes are still on disk — see `liftForExport`.
    private var lifted: [UUID: (item: ShelfItem, index: Int)] = [:]

    init(
        repository: StagingRepository,
        settings: AppSettings
    ) {
        self.repository = repository
        self.settings = settings
        pipeline = TransferPipeline(repository: repository)
    }

    var exportedURLs: [URL] {
        items.compactMap { $0.fileURL(inside: repository.rootURL) }
    }

    func restore() {
        items = repository.load()
        pruneExpiredItems()
        logger.info("Restored \(self.items.count, privacy: .public) shelf items")
    }

    func importFileURLs(_ urls: [URL]) {
        for url in urls {
            let transferID = UUID()
            pendingTransfers.append(
                PendingTransfer(
                    id: transferID,
                    displayName: url.lastPathComponent,
                    phase: .waitingForSource
                )
            )

            Task {
                do {
                    let item = try await pipeline.stageFile(
                        at: url,
                        itemID: transferID
                    ) { [weak self] phase in
                        Task { @MainActor [weak self] in
                            self?.updateTransfer(transferID, phase: phase)
                        }
                    }
                    finishTransfer(transferID, with: .success(item))
                } catch {
                    finishTransfer(transferID, with: .failure(error))
                }
            }
        }
    }

    func importText(_ text: String, suggestedName: String = "Text.txt") {
        let transferID = UUID()
        pendingTransfers.append(
            PendingTransfer(id: transferID, displayName: suggestedName, phase: .copying)
        )
        Task {
            do {
                let item = try await pipeline.stageText(
                    text,
                    suggestedName: suggestedName,
                    itemID: transferID
                )
                finishTransfer(transferID, with: .success(item))
            } catch {
                finishTransfer(transferID, with: .failure(error))
            }
        }
    }

    func importData(_ data: Data, suggestedName: String) {
        let transferID = UUID()
        pendingTransfers.append(
            PendingTransfer(id: transferID, displayName: suggestedName, phase: .copying)
        )
        Task {
            do {
                let item = try await pipeline.stageData(
                    data,
                    suggestedName: suggestedName,
                    itemID: transferID
                )
                finishTransfer(transferID, with: .success(item))
            } catch {
                finishTransfer(transferID, with: .failure(error))
            }
        }
    }

    func importImage(_ image: NSImage) {
        let transferID = UUID()
        pendingTransfers.append(
            PendingTransfer(id: transferID, displayName: "Image.png", phase: .copying)
        )
        Task {
            do {
                let item = try await pipeline.stageImage(image, itemID: transferID)
                finishTransfer(transferID, with: .success(item))
            } catch {
                finishTransfer(transferID, with: .failure(error))
            }
        }
    }

    // MARK: - Finder Action arrivals

    /// Reserve shelf slots before the extension asks Finder for any bytes.
    /// The response persisted in the App Group is the admission receipt; its
    /// IDs also make pending reservations recoverable across an app relaunch.
    ///
    /// The running app takes everything it is offered — the handshake exists so
    /// the extension never copies bytes perch isn't there to adopt, not to
    /// ration tiles.
    func admitFinderItems(_ offered: [FinderActionItem]) -> [FinderActionItem] {
        resumeFinderItems(offered)
        return offered
    }

    func resumeFinderItems(_ accepted: [FinderActionItem]) {
        for item in accepted where !items.contains(where: { $0.id == item.id })
            && !pendingTransfers.contains(where: { $0.id == item.id }) {
            pendingTransfers.append(
                PendingTransfer(id: item.id, displayName: item.displayName, phase: .copying)
            )
        }
    }

    func completeFinderImport(_ offered: FinderActionItem, stagedAt url: URL) async {
        guard pendingTransfers.contains(where: { $0.id == offered.id }) else { return }
        do {
            let item = try await pipeline.adoptPreparedFile(
                at: url,
                suggestedName: offered.displayName,
                itemID: offered.id
            )
            finishTransfer(offered.id, with: .success(item))
        } catch {
            finishTransfer(offered.id, with: .failure(error))
        }
    }

    func failFinderImport(_ offered: FinderActionItem) {
        guard pendingTransfers.contains(where: { $0.id == offered.id }) else { return }
        finishTransfer(
            offered.id,
            with: .failure(FinderActionImportError.unavailable(offered.displayName))
        )
    }

    func beginPromisedImports(_ receivers: [NSFilePromiseReceiver]) {
        guard !receivers.isEmpty else { return }
        let batchID = UUID()
        let batchDirectory: URL
        do {
            batchDirectory = try repository.allocateImportDirectory(id: batchID)
            try Data().write(to: batchDirectory.appending(path: ".receiving"))
        } catch {
            report(error)
            return
        }

        let batchTracker = PromiseBatchTracker(directory: batchDirectory)
        for (index, receiver) in receivers.enumerated() {
            let transferID = UUID()
            let fallbackName = receiver.fileTypes.first ?? "Promised item \(index + 1)"
            pendingTransfers.append(
                PendingTransfer(
                    id: transferID,
                    displayName: fallbackName,
                    phase: .waitingForSource
                )
            )
            receiver.receivePromisedFiles(
                atDestination: batchDirectory,
                options: [:],
                operationQueue: promisedFileQueue
            ) { @Sendable [weak self] url, error in
                // AppKit invokes this completion on `promisedFileQueue` (a
                // background OperationQueue), NOT the main actor. Marking the
                // closure @Sendable keeps it nonisolated so the Swift runtime
                // does not assert main-actor isolation on entry (that assert
                // was crashing the app on every promised drop). All UI/state
                // access below hops to the main actor explicitly.
                Task { [weak self] in
                    guard let self else { return }
                    if let error {
                        await MainActor.run {
                            self.finishTransfer(transferID, with: .failure(error))
                        }
                        batchTracker.completeOne()
                        return
                    }
                    do {
                        let item = try await self.pipeline.adoptPromisedFile(
                            at: url,
                            itemID: UUID()
                        )
                        await MainActor.run {
                            self.commitPromisedItem(item, pendingID: transferID)
                        }
                    } catch {
                        await MainActor.run {
                            self.finishTransfer(transferID, with: .failure(error))
                        }
                    }
                    batchTracker.completeOne()
                }
            }
            batchTracker.expect(max(1, receiver.fileNames.count))
        }
        batchTracker.finishScheduling()
    }

    // MARK: - Mobile arrivals
    //
    // The same shape as every other import: admission decided before any
    // bytes move, a pending tile while bytes arrive, and the commit path
    // converging on `finishTransfer`. The wire server verifies digests; by
    // the time a file reaches `completeMobileImport` it is complete and
    // already on the shelf's volume.

    /// Where the wire server spools partial arrivals. Hidden (dot-named)
    /// inside the shelf root so recovery and cleanup never mistake a
    /// half-arrived file for shelf content, while staying on the same volume
    /// for an atomic final move.
    nonisolated static func mobileSpoolRoot(inside shelfRoot: URL) -> URL {
        shelfRoot.appending(path: ".mobile-spool", directoryHint: .isDirectory)
    }

    /// Admission for a phone's offer, before the phone sends a byte. Each
    /// accepted item gets a pending tile so an arrival is visible while it
    /// streams.
    func admitMobileItems(
        _ offered: [OfferedItem],
        deviceName: String
    ) -> (accepted: [OfferedItem], refused: [RefusedItem]) {
        for item in offered {
            pendingTransfers.append(
                PendingTransfer(id: item.id, displayName: item.displayName, phase: .copying)
            )
        }
        // The wire keeps a refusal channel — the phone knows how to hear one —
        // but the Mac has nothing left to refuse an offer for: every item a
        // paired device sends gets a pending tile and a slot.
        return (offered, [])
    }

    /// A verified, complete arrival: move it out of the spool into its own
    /// container and onto the shelf. The move is a same-volume rename — the
    /// bytes were already written to this volume by the wire server, off main.
    func completeMobileImport(_ offered: OfferedItem, spooledAt spoolURL: URL) throws {
        var container: URL?
        do {
            let allocated = try repository.allocateImportDirectory(id: offered.id)
            container = allocated
            let destination = allocated.appending(
                path: StagingRepository.safeFilename(offered.displayName)
            )
            try FileManager.default.moveItem(at: spoolURL, to: destination)
            let item = try repository.item(forStagedURL: destination, id: offered.id)
            finishTransfer(offered.id, with: .success(item))
        } catch {
            // Leaving the container behind would poison every retry of this
            // item: the phone keeps its ID, and allocation would then throw
            // "already exists" forever.
            if let container {
                try? FileManager.default.removeItem(at: container)
            }
            finishTransfer(offered.id, with: .failure(error))
            throw error
        }
    }

    /// The stream died or the bytes were wrong — drop the pending tile.
    func failMobileImport(_ itemID: UUID) {
        pendingTransfers.removeAll { $0.id == itemID }
    }

    func remove(_ item: ShelfItem) {
        do {
            try repository.remove(item)
            items.removeAll { $0.id == item.id }
            try repository.persist(items)
        } catch {
            report(error)
        }
    }

    func setPinned(_ pinned: Bool, for item: ShelfItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              items[index].isPinned != pinned
        else {
            return
        }
        items[index].isPinned = pinned
        do {
            try repository.persist(items)
        } catch {
            report(error)
        }
    }

    /// A drop was accepted: take unpinned items off the shelf now, before
    /// anything has read them. Pinned items deliberately stay available for
    /// another drag and never enter the lifted/deletion transaction.
    ///
    /// Letting go *is* the gesture — a shelf that keeps counting an item until
    /// its receiver reports back reads as stuck, and the receiver may never
    /// report at all. The staged bytes are untouched, so the destination can
    /// still read them and `returnToShelf` can put a refused item back exactly
    /// where it was. What finally happens to those bytes is settled by
    /// `confirmCopied` (deleted) or `handOff` (detached).
    func liftForExport(_ ids: Set<UUID>) {
        for id in ids {
            guard let index = items.firstIndex(where: { $0.id == id }),
                  !items[index].isPinned
            else {
                continue
            }
            lifted[id] = (items[index], index)
        }
        items.removeAll { ids.contains($0.id) && !$0.isPinned }
        // The manifest drops them too: if Perch dies mid-export the bytes are
        // still on disk and recovery re-adopts them — nothing is ever lost by
        // lifting optimistically.
        do {
            try repository.persist(items)
        } catch {
            report(error)
        }
    }

    /// The destination refused the item or its copy failed — put it back where
    /// it was. Never removes anything: that was the -8058 data-loss bug.
    func returnToShelf(_ id: UUID) {
        guard let entry = lifted.removeValue(forKey: id) else { return }
        items.insert(entry.item, at: min(entry.index, items.count))
        do {
            try repository.persist(items)
        } catch {
            report(error)
        }
    }

    /// The destination confirmed it holds its own copy — the staged one can go.
    func confirmCopied(_ id: UUID) {
        guard let entry = lifted.removeValue(forKey: id) else { return }
        do {
            try repository.remove(entry.item)
        } catch {
            report(error)
        }
    }

    /// Drag-out to a destination that took the staged file URL directly instead
    /// of asking for the promise — every terminal, most editors. Nothing ever
    /// reports back, so nothing will ever confirm the copy: the bytes are
    /// detached rather than deleted, because whatever received the drop is still
    /// holding a path into them. See `StagingRepository.detach`.
    func handOff(_ ids: Set<UUID>) {
        for id in ids {
            guard let entry = lifted.removeValue(forKey: id) else { continue }
            do {
                try repository.detach(entry.item)
            } catch {
                report(error)
            }
        }
    }

    func clear() {
        do {
            try repository.removeAll()
            items = []
        } catch {
            report(error)
        }
    }

    func reveal(_ item: ShelfItem) {
        guard let url = item.fileURL(inside: repository.rootURL) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Double-click behaviour: preview quick-lookable content (images) in the
    /// slim Quick Look panel rather than launching a heavyweight viewer app;
    /// hand everything else to its default app.
    ///
    /// Quick Look runs via `qlmanage -p` in its own process on purpose: the
    /// shelf lives on a non-activating, non-key panel that deliberately never
    /// steals focus, so the in-process `QLPreviewPanel` (which demands a key
    /// window + responder-chain controller) can't be driven without breaking
    /// that design. The out-of-process previewer sidesteps all of it.
    func open(_ item: ShelfItem) {
        guard let url = item.fileURL(inside: repository.rootURL) else { return }
        if shouldQuickLook(item) {
            quickLook(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func shouldQuickLook(_ item: ShelfItem) -> Bool {
        if item.kind == .image { return true }
        return item.contentType?.conforms(to: .image) ?? false
    }

    private func quickLook(_ url: URL) {
        // Replace any preview already on screen. qlmanage lives only as long as
        // its window, so terminating the last one stops double-clicks piling up
        // a stack of Quick Look windows.
        quickLookProcess?.terminate()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", url.path]
        // qlmanage is chatty on both streams; keep the shelf's console clean.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            quickLookProcess = process
            // Perch is an accessory app that never activates, so qlmanage's
            // window opens behind whatever the user is focused on — looking
            // like the double-click did nothing. Raise it by its pid once the
            // window exists.
            raiseQuickLookWindow(pid: process.processIdentifier)
        } catch {
            // If Quick Look can't launch, fall back to the default app so a
            // double-click never silently does nothing.
            NSWorkspace.shared.open(url)
        }
    }

    /// Bring the just-launched qlmanage preview to the front. The window is not
    /// up the instant the process starts, so poll briefly for it to register as
    /// a running app, then nudge it forward a couple of times to beat layout.
    private func raiseQuickLookWindow(pid: pid_t, attempt: Int = 0) {
        guard attempt < 15 else { return }
        if let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            app.activate(options: [.activateAllWindows])
            if attempt < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.raiseQuickLookWindow(pid: pid, attempt: attempt + 1)
                }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.raiseQuickLookWindow(pid: pid, attempt: attempt + 1)
        }
    }

    private func updateTransfer(_ id: UUID, phase: PendingTransfer.Phase) {
        guard let index = pendingTransfers.firstIndex(where: { $0.id == id }) else { return }
        pendingTransfers[index].phase = phase
    }

    private func finishTransfer(_ id: UUID, with result: Result<ShelfItem, Error>) {
        pendingTransfers.removeAll { $0.id == id }
        switch result {
        case let .success(item):
            items.append(item)
            do {
                try repository.persist(items)
            } catch {
                report(error)
            }
        case let .failure(error):
            report(error)
        }
    }

    private func commitPromisedItem(_ item: ShelfItem, pendingID: UUID) {
        if pendingTransfers.contains(where: { $0.id == pendingID }) {
            finishTransfer(pendingID, with: .success(item))
            return
        }
        items.append(item)
        do {
            try repository.persist(items)
        } catch {
            report(error)
        }
    }

    /// The date an item must be newer than to survive, or `nil` when retention
    /// is off and nothing expires at all.
    ///
    /// Static and pure so the rule that actually matters — *is expiry even on* —
    /// is a value question rather than a live-store one: it can be asked of a
    /// bare integer, at whatever `now` a test likes, with no shelf, no
    /// repository and no settings object in the way.
    ///
    /// Note the `nil` on failed date arithmetic. This used to be
    /// `?? .distantPast`, which is the wrong direction to fail in: a cutoff of
    /// `.distantPast` is newer than nothing, so it would have expired the entire
    /// shelf. When we can't say what's old, nothing is old.
    static func expiryCutoff(
        retentionDays: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        guard retentionDays > 0 else { return nil }
        return calendar.date(byAdding: .day, value: -retentionDays, to: now)
    }

    private func pruneExpiredItems() {
        // Retention is off by default (see `AppSettings.retentionDays`), and off
        // means off: nothing on the shelf is removed unless you remove it.
        guard let cutoff = Self.expiryCutoff(retentionDays: settings.retentionDays) else {
            return
        }
        do {
            items = try repository.prune(olderThan: cutoff, items: items)
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        latestError = error.localizedDescription
        logger.error("Shelf operation failed: \(error.localizedDescription, privacy: .public)")
    }

    private let promisedFileQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.hausfold.perch.promises"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
}

private enum FinderActionImportError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(name):
            "Finder could not add \(name) to the shelf."
        }
    }
}

private final class PromiseBatchTracker: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var expected = 0
    private var completed = 0
    private var schedulingFinished = false

    init(directory: URL) {
        self.directory = directory
    }

    func expect(_ count: Int) {
        lock.withLock {
            expected += count
        }
    }

    func finishScheduling() {
        lock.withLock {
            schedulingFinished = true
            cleanIfFinished()
        }
    }

    func completeOne() {
        lock.withLock {
            completed += 1
            cleanIfFinished()
        }
    }

    private func cleanIfFinished() {
        guard schedulingFinished, completed >= expected else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
