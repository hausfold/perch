import Foundation
import UniformTypeIdentifiers

/// Finder owns the source URLs and Perch owns admission. The extension first
/// publishes only stable IDs, display names, and in-memory attachment indexes;
/// it does not ask an item provider for a URL until the app has reserved that
/// item's shelf slot. Copies run on a bounded background queue and finish in
/// the App Group before their relative paths are published back to Perch.
final class ActionRequestHandler: NSObject, NSExtensionRequestHandling, @unchecked Sendable {
    /// Foundation's extension-context types predate Sendable annotations. The
    /// host owns them for exactly this request, and we keep them together so
    /// the background handoff cannot outlive or mix invocations.
    private final class Invocation: @unchecked Sendable {
        let context: NSExtensionContext
        let inputItem: NSExtensionItem
        let attachments: [NSItemProvider]

        init(
            context: NSExtensionContext,
            inputItem: NSExtensionItem,
            attachments: [NSItemProvider]
        ) {
            self.context = context
            self.inputItem = inputItem
            self.attachments = attachments
        }
    }

    private final class ProviderReference: @unchecked Sendable {
        let provider: NSItemProvider

        init(_ provider: NSItemProvider) {
            self.provider = provider
        }
    }

    private final class StagingAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var staged: [FinderActionStagedItem] = []
        private var failed: [UUID] = []

        func recordStaged(_ item: FinderActionStagedItem) {
            lock.withLock { staged.append(item) }
        }

        func recordFailure(_ id: UUID) {
            lock.withLock { failed.append(id) }
        }

        func completion() -> FinderActionCompletion {
            lock.withLock {
                FinderActionCompletion(
                    stagedItems: staged.sorted { $0.id.uuidString < $1.id.uuidString },
                    failedItemIDs: failed.sorted { $0.uuidString < $1.uuidString }
                )
            }
        }
    }

    private let workQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.hausfold.perch.finder-action"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    func beginRequest(with context: NSExtensionContext) {
        guard let inputItem = context.inputItems.first as? NSExtensionItem,
              let attachments = inputItem.attachments,
              !attachments.isEmpty
        else {
            cancel(context, message: "Finder did not provide any files.")
            return
        }
        let invocation = Invocation(
            context: context,
            inputItem: inputItem,
            attachments: attachments
        )

        let request = FinderActionRequest(
            id: UUID(),
            createdAt: Date(),
            items: attachments.enumerated().map { index, provider in
                FinderActionItem(
                    id: UUID(),
                    displayName: FinderActionProtocol.safeFilename(
                        provider.suggestedName ?? "Item \(index + 1)"
                    ),
                    attachmentIndex: index
                )
            }
        )

        workQueue.addOperation { [weak self] in
            guard let self else { return }
            do {
                let mailbox = try FinderActionMailbox()
                try mailbox.createRequest(request)
                guard let response = try self.waitForAdmission(
                    requestID: request.id,
                    mailbox: mailbox
                ) else {
                    // Do not delete the request here: the app may have reserved
                    // slots while its atomic response was racing this timeout.
                    // An empty completion lets it release any such reservation
                    // on the next scan; an unopened app reaps it as stale later.
                    try? mailbox.writeCompletion(
                        FinderActionCompletion(stagedItems: [], failedItemIDs: []),
                        for: request.id
                    )
                    self.cancel(
                        invocation.context,
                        message: "Open Perch and try the Finder action again."
                    )
                    return
                }
                self.stageAcceptedItems(
                    request: request,
                    response: response,
                    attachments: invocation.attachments,
                    mailbox: mailbox
                ) { completion in
                    do {
                        try mailbox.writeCompletion(completion, for: request.id)
                        self.complete(
                            invocation.context,
                            returning: [invocation.inputItem]
                        )
                    } catch {
                        self.cancel(
                            invocation.context,
                            message: "Perch could not finish the Finder handoff."
                        )
                    }
                }
            } catch {
                self.cancel(
                    invocation.context,
                    message: "Perch's Finder action is unavailable."
                )
            }
        }
    }

    private func waitForAdmission(
        requestID: UUID,
        mailbox: FinderActionMailbox
    ) throws -> FinderActionResponse? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let response = try mailbox.readResponse(for: requestID) {
                return response
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private func stageAcceptedItems(
        request: FinderActionRequest,
        response: FinderActionResponse,
        attachments: [NSItemProvider],
        mailbox: FinderActionMailbox,
        completion: @escaping @Sendable (FinderActionCompletion) -> Void
    ) {
        let acceptedIDs = Set(response.acceptedItemIDs)
        let accepted = request.items.filter { acceptedIDs.contains($0.id) }
        guard !accepted.isEmpty else {
            completion(FinderActionCompletion(stagedItems: [], failedItemIDs: []))
            return
        }

        let group = DispatchGroup()
        let accumulator = StagingAccumulator()

        for item in accepted {
            guard attachments.indices.contains(item.attachmentIndex) else {
                accumulator.recordFailure(item.id)
                continue
            }
            let provider = attachments[item.attachmentIndex]
            guard let typeIdentifier = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .item) == true
            }) ?? provider.registeredTypeIdentifiers.first else {
                accumulator.recordFailure(item.id)
                continue
            }

            group.enter()
            let providerReference = ProviderReference(provider)
            workQueue.addOperation { [weak self] in
                guard let self else {
                    accumulator.recordFailure(item.id)
                    group.leave()
                    return
                }
                let loaded = DispatchSemaphore(value: 0)
                providerReference.provider.loadInPlaceFileRepresentation(
                    forTypeIdentifier: typeIdentifier
                ) { [weak self] sourceURL, _, _ in
                    defer { loaded.signal() }
                    guard let self, let sourceURL else {
                        accumulator.recordFailure(item.id)
                        return
                    }
                    let copied = DispatchSemaphore(value: 0)
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer { copied.signal() }
                        do {
                            let destination = try self.copyIntoMailbox(
                                sourceURL: sourceURL,
                                item: item,
                                requestID: request.id,
                                mailbox: mailbox
                            )
                            let relativePath = try mailbox.relativePath(
                                for: destination,
                                requestID: request.id
                            )
                            accumulator.recordStaged(
                                FinderActionStagedItem(id: item.id, relativePath: relativePath)
                            )
                        } catch {
                            accumulator.recordFailure(item.id)
                        }
                    }
                    // Keep a temporary provider URL alive until its off-main
                    // coordinated copy finishes, even if Finder called this
                    // completion on its own UI thread.
                    copied.wait()
                }
                // Keep this bounded operation alive until the provider callback
                // finishes. Its temporary URL is valid only during that callback,
                // so the coordinated copy above intentionally happens inline.
                loaded.wait()
                group.leave()
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            completion(accumulator.completion())
        }
    }

    private func copyIntoMailbox(
        sourceURL: URL,
        item: FinderActionItem,
        requestID: UUID,
        mailbox: FinderActionMailbox
    ) throws -> URL {
        let fileManager = FileManager()
        let directory = try mailbox.stagedDirectory(for: requestID, itemID: item.id)
        let destination = directory.appending(path: item.displayName)
        let partial = directory.appending(path: ".\(item.id.uuidString).partial")
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped { sourceURL.stopAccessingSecurityScopedResource() }
        }

        var coordinationError: NSError?
        var copyResult: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(
            readingItemAt: sourceURL,
            options: [.withoutChanges],
            error: &coordinationError
        ) { coordinatedURL in
            copyResult = Result {
                try fileManager.copyItem(at: coordinatedURL, to: partial)
                try fileManager.moveItem(at: partial, to: destination)
            }
        }
        if let coordinationError { throw coordinationError }
        try copyResult.get()
        return destination
    }

    private func complete(_ context: NSExtensionContext, returning items: [Any]) {
        // Return Finder's original providers unchanged. An editor-style Action
        // that omits them can cause Finder to replace/delete input.
        context.completeRequest(returningItems: items, completionHandler: nil)
    }

    private func cancel(_ context: NSExtensionContext, message: String) {
        context.cancelRequest(
            withError: NSError(
                domain: "com.hausfold.perch.finder-action",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        )
    }
}
