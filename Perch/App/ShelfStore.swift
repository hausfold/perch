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
    private let logger = Logger(subsystem: "com.nebelhaus.perch", category: "Shelf")
    // The live `qlmanage -p` preview, if any, so a new double-click can replace
    // it instead of stacking another window on top.
    private var quickLookProcess: Process?

    init(repository: StagingRepository, settings: AppSettings) {
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

    func remove(_ item: ShelfItem) {
        do {
            try repository.remove(item)
            items.removeAll { $0.id == item.id }
            try repository.persist(items)
        } catch {
            report(error)
        }
    }

    /// Drag-out to a destination that took the staged file URL directly instead
    /// of asking for the promise — every terminal, most editors. Nothing ever
    /// reports back, so the items leave the shelf on the drag's own terms, but
    /// their bytes are only detached, not deleted: whatever received the drop is
    /// still holding a path into them. See `StagingRepository.detach`.
    func handOff(_ ids: Set<UUID>) {
        let leaving = items.filter { ids.contains($0.id) }
        guard !leaving.isEmpty else { return }
        do {
            for item in leaving {
                try repository.detach(item)
            }
            items.removeAll { ids.contains($0.id) }
            try repository.persist(items)
        } catch {
            report(error)
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

    private func pruneExpiredItems() {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -settings.retentionDays,
            to: Date()
        ) ?? .distantPast
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
        queue.name = "com.nebelhaus.perch.promises"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
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
