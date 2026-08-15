import AppKit
import Foundation
import UniformTypeIdentifiers

enum TransferPipelineError: LocalizedError {
    case cloudDownloadTimedOut
    case imageEncodingFailed
    case noReadableRepresentation

    var errorDescription: String? {
        switch self {
        case .cloudDownloadTimedOut:
            "The iCloud item did not finish downloading in time. Try the drop again after it is available locally."
        case .imageEncodingFailed:
            "The dropped image could not be encoded."
        case .noReadableRepresentation:
            "That item does not expose a file, image, link, or text representation."
        }
    }
}

struct StagedTransfer: Sendable {
    let item: ShelfItem
    let phase: PendingTransfer.Phase
}

final class TransferPipeline: @unchecked Sendable {
    private let repository: StagingRepository
    private let queue: OperationQueue

    init(repository: StagingRepository) {
        self.repository = repository
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
        try await withCheckedThrowingContinuation { continuation in
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
                    if try Self.isUndownloadedCloudItem(sourceURL) {
                        phaseChanged(.downloadingFromCloud)
                        try fileManager.startDownloadingUbiquitousItem(at: sourceURL)
                        try Self.waitForCloudDownload(sourceURL)
                    }
                    phaseChanged(.copying)

                    let allocatedContainer = try repository.allocateImportDirectory(id: itemID)
                    container = allocatedContainer
                    let destination = allocatedContainer.appending(
                        path: Self.safeFilename(sourceURL.lastPathComponent)
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
                path: Self.safeFilename(receivedURL.lastPathComponent)
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
                path: Self.safeFilename(suggestedName)
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
            let destination = container.appending(path: Self.safeFilename(suggestedName))
            try data.write(to: destination, options: [.atomic])
            return try self.repository.item(forStagedURL: destination, id: itemID)
        }
    }

    func stageText(_ text: String, suggestedName: String, itemID: UUID) async throws -> ShelfItem {
        try await enqueue {
            let container = try self.repository.allocateImportDirectory(id: itemID)
            let destination = container.appending(path: Self.safeFilename(suggestedName))
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

    private static func safeFilename(_ candidate: String) -> String {
        StagingRepository.safeFilename(candidate)
    }

    private static func isUndownloadedCloudItem(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ])
        return values.isUbiquitousItem == true
            && values.ubiquitousItemDownloadingStatus != .current
    }

    private static func waitForCloudDownload(_ url: URL) throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let values = try url.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemIsDownloadingKey,
                .ubiquitousItemDownloadingErrorKey,
            ])
            if let error = values.ubiquitousItemDownloadingError {
                throw error
            }
            if values.ubiquitousItemDownloadingStatus == .current
                || values.ubiquitousItemDownloadingStatus == .downloaded {
                return
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        throw TransferPipelineError.cloudDownloadTimedOut
    }
}
