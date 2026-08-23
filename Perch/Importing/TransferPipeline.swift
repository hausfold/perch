import AppKit
import Foundation
import UniformTypeIdentifiers

enum TransferPipelineError: LocalizedError {
    case cloudDownloadTimedOut
    case cloudDownloadNeverStarted
    case cloudDownloadFailed
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .cloudDownloadTimedOut:
            "The iCloud item did not finish downloading in time. Try the drop again after it is available locally."
        case .cloudDownloadNeverStarted:
            "iCloud did not start fetching that item. Open it in Finder to download it, then drop it again."
        case .cloudDownloadFailed:
            "iCloud could not download that item. Try the drop again once it is available locally."
        case .imageEncodingFailed:
            "The dropped image could not be encoded."
        }
    }
}

final class TransferPipeline: @unchecked Sendable {
    private let repository: StagingRepository
    private let queue: OperationQueue
    private let cloudWaiter: CloudDownloadWaiter

    init(repository: StagingRepository, cloudWaiter: CloudDownloadWaiter = CloudDownloadWaiter()) {
        self.repository = repository
        self.cloudWaiter = cloudWaiter
        queue = OperationQueue()
        queue.name = "com.hausfold.perch.transfer"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
    }

    func stageFile(
        at sourceURL: URL,
        itemID: UUID,
        phaseChanged: @escaping @Sendable (PendingTransfer.Phase) -> Void
    ) async throws -> ShelfItem {
        // Before the queue, not on it. A cloud download can last two minutes
        // and the queue has two slots, so waiting inside an operation stalls
        // every other drop behind a file nobody is copying yet (#2).
        try await downloadFromCloudIfNeeded(sourceURL, phaseChanged: phaseChanged)

        return try await withCheckedThrowingContinuation { continuation in
            queue.addOperation { [repository] in
                let fileManager = FileManager()
                let scoped = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if scoped {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }

                var container: URL?
                do {
                    phaseChanged(.copying)

                    let allocatedContainer = try repository.allocateImportDirectory(id: itemID)
                    container = allocatedContainer
                    let destination = allocatedContainer.appending(
                        path: StagingRepository.safeFilename(sourceURL.lastPathComponent)
                    )
                    let partial = allocatedContainer.appending(
                        path: ".\(itemID.uuidString).partial"
                    )
                    var coordinationError: NSError?
                    var copyResult: Result<Void, Error> = .success(())
                    let coordinator = NSFileCoordinator()
                    coordinator.coordinate(
                        readingItemAt: sourceURL,
                        options: [.withoutChanges],
                        error: &coordinationError
                    ) { coordinatedURL in
                        copyResult = Result {
                            try fileManager.copyItem(at: coordinatedURL, to: partial)
                            try fileManager.moveItem(at: partial, to: destination)
                        }
                    }
                    if let coordinationError {
                        throw coordinationError
                    }
                    try copyResult.get()
                    continuation.resume(returning: try repository.item(forStagedURL: destination, id: itemID))
                } catch {
                    if let container {
                        try? fileManager.removeItem(at: container)
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func adoptPromisedFile(at receivedURL: URL, itemID: UUID) async throws -> ShelfItem {
        try await enqueue {
            let fileManager = FileManager()
            let container = try self.repository.allocateImportDirectory(id: itemID)
            let destination = container.appending(
                path: StagingRepository.safeFilename(receivedURL.lastPathComponent)
            )
            do {
                try fileManager.moveItem(at: receivedURL, to: destination)
                return try self.repository.item(forStagedURL: destination, id: itemID)
            } catch {
                try? fileManager.removeItem(at: container)
                throw error
            }
        }
    }

    /// Moves a complete representation prepared by another Perch process into
    /// the shelf. Finder Action bytes reach here only after `ShelfStore`
    /// reserved their slots, and the App Group source is already complete.
    func adoptPreparedFile(
        at preparedURL: URL,
        suggestedName: String,
        itemID: UUID
    ) async throws -> ShelfItem {
        try await enqueue {
            let fileManager = FileManager()
            let container = try self.repository.allocateImportDirectory(id: itemID)
            let destination = container.appending(
                path: StagingRepository.safeFilename(suggestedName)
            )
            do {
                do {
                    try fileManager.moveItem(at: preparedURL, to: destination)
                } catch {
                    // App Group and app containers normally share a volume, but
                    // copy remains a correct fallback if the filesystem refuses
                    // a cross-container rename. This queue is never main.
                    try fileManager.copyItem(at: preparedURL, to: destination)
                    try? fileManager.removeItem(at: preparedURL)
                }
                return try self.repository.item(forStagedURL: destination, id: itemID)
            } catch {
                try? fileManager.removeItem(at: container)
                throw error
            }
        }
    }

    func stageData(_ data: Data, suggestedName: String, itemID: UUID) async throws -> ShelfItem {
        try await enqueue {
            let container = try self.repository.allocateImportDirectory(id: itemID)
            let destination = container.appending(path: StagingRepository.safeFilename(suggestedName))
            try data.write(to: destination, options: [.atomic])
            return try self.repository.item(forStagedURL: destination, id: itemID)
        }
    }

    func stageText(_ text: String, suggestedName: String, itemID: UUID) async throws -> ShelfItem {
        try await enqueue {
            let container = try self.repository.allocateImportDirectory(id: itemID)
            let destination = container.appending(path: StagingRepository.safeFilename(suggestedName))
            try text.write(to: destination, atomically: true, encoding: .utf8)
            return try self.repository.item(forStagedURL: destination, id: itemID)
        }
    }

    func stageImage(_ image: NSImage, itemID: UUID) async throws -> ShelfItem {
        try await enqueue {
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else {
                throw TransferPipelineError.imageEncodingFailed
            }
            let container = try self.repository.allocateImportDirectory(id: itemID)
            let destination = container.appending(path: "Image.png")
            try png.write(to: destination, options: [.atomic])
            return try self.repository.item(forStagedURL: destination, id: itemID)
        }
    }

    /// Writes a staged representation out to a location the user picked in a
    /// save panel. The staged copy is only read — saving is not an export, so
    /// nothing is lifted, deleted, or detached, and the tile stays put.
    ///
    /// Runs on the same bounded queue as importing for the same reason imports
    /// do: this is a copy of arbitrary size and the main actor never performs
    /// one.
    func copyOut(from stagedURL: URL, to destination: URL) async throws {
        try await enqueue {
            let fileManager = FileManager()
            // A save panel's default destinations are `~/Downloads` and
            // `~/Desktop`, which are also the folders people watch — so this
            // is the same round-trip a drag-out is, and it is announced the
            // same way. Reserved before the first byte, because that write is
            // the directory event that starts the folder's scan. See
            // `ExportLedger`. The replace branch below needs it just as much:
            // `replaceItemAt` swaps in a file from the replacement directory,
            // so even overwriting something already ledgered lands a fresh
            // identity.
            let ledger = ExportLedger.shared
            ledger.willWrite(to: destination)
            do {
                try Self.write(from: stagedURL, to: destination, using: fileManager)
            } catch {
                ledger.cancelWrite(at: destination)
                throw error
            }
            ledger.didWrite(to: destination)
        }
    }

    private static func write(
        from stagedURL: URL,
        to destination: URL,
        using fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: destination.path) else {
            try fileManager.copyItem(at: stagedURL, to: destination)
            return
        }
        // The panel already asked before overwriting, but asking is all it
        // does — it never removes the file, and `copyItem` refuses a
        // destination that exists.
        //
        // Deleting it first would put the *user's* file in a window this
        // app has no business opening: a copy that then fails — a full
        // volume, a folder that copies halfway — leaves them with neither
        // their old file nor a new one, and perch is sandboxed so nothing
        // went to the Trash. Replace is a promise of replacement, not of
        // deletion-then-maybe. So copy into the volume's own replacement
        // directory and swap the finished copy in atomically; a failure
        // anywhere before the swap leaves the destination exactly as it
        // was. `.itemReplacementDirectory` is deliberate — it is the
        // temporary location the panel's grant reaches, whereas a sibling
        // temp file beside the destination is not covered by it.
        let scratch = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destination,
            create: true
        )
        defer { try? fileManager.removeItem(at: scratch) }
        let pending = scratch.appending(path: destination.lastPathComponent)
        try fileManager.copyItem(at: stagedURL, to: pending)
        _ = try fileManager.replaceItemAt(destination, withItemAt: pending)
    }

    private func enqueue<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }

    /// Asks iCloud for an evicted file and waits for it, reporting the wait to
    /// the tile. A no-op for everything already local, which is every drop that
    /// is not an evicted iCloud item.
    private func downloadFromCloudIfNeeded(
        _ sourceURL: URL,
        phaseChanged: @escaping @Sendable (PendingTransfer.Phase) -> Void
    ) async throws {
        // Inside the scope, not before it: this guard is on the path of every
        // import, and reading resource values from a security-scoped URL
        // (a Shortcuts `IntentFile`, say) throws without the grant held.
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        // Both of these are blocking syscalls too — the first on the path of
        // *every* import, the second an XPC round trip to the ubiquity daemon —
        // so they go off the cooperative pool with the polls (`CloudSyscallQueue`).
        // Holding the security scope across the hop is fine: the grant is
        // process-wide, not thread-local.
        guard try await CloudSyscallQueue.run({ [cloudWaiter] in
            try cloudWaiter.isUndownloadedCloudItem(sourceURL)
        }) else { return }
        phaseChanged(.downloadingFromCloud(elapsedSeconds: 0))
        try await CloudSyscallQueue.run { [cloudWaiter] in
            try cloudWaiter.startDownload(sourceURL)
        }
        try await cloudWaiter.wait(for: sourceURL) { elapsed in
            phaseChanged(.downloadingFromCloud(elapsedSeconds: elapsed))
        }
    }
}
