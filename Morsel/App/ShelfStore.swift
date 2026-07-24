import AppKit
import Foundation
import OSLog

@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var pendingTransfers: [PendingTransfer] = []
    @Published var latestError: String?

    let repository: StagingRepository

    private let pipeline: TransferPipeline
    private let settings: AppSettings
    private let logger = Logger(subsystem: "com.nebelhaus.morsel", category: "Shelf")

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
            ) { [weak self] url, error in
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

    func clear() {
        do {
            try repository.removeAll()
            items = []
        } catch {
            report(error)
        }
    }

    func completeExport() {
        if settings.autoRemoveAfterExport {
            clear()
        }
    }

    func reveal(_ item: ShelfItem) {
        guard let url = item.fileURL(inside: repository.rootURL) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
        queue.name = "com.nebelhaus.morsel.promises"
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
