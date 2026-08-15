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

        let displayNames = attachments.enumerated().map { index, provider in
            provider.suggestedName ?? "Item \(index + 1)"
        }

        workQueue.addOperation { [weak self] in
            guard let self else { return }
            do {
                let client = try HandoffClient()
                let request = try client.openRequest(displayNames: displayNames)
                guard let response = try client.waitForAdmission(
                    request.id,
                    deadline: Date().addingTimeInterval(5)
                ) else {
                    // Do not delete the request here: the app may have reserved
                    // slots while its atomic response was racing this timeout.
                    // An empty completion lets it release any such reservation
                    // on the next scan; an unopened app reaps it as stale later.
                    client.abandon(request.id)
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
                    client: client
                ) { completion in
                    do {
                        try client.finish(completion, for: request.id)
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

    private func stageAcceptedItems(
        request: FinderActionRequest,
        response: FinderActionResponse,
        attachments: [NSItemProvider],
        client: HandoffClient,
        completion: @escaping @Sendable (FinderActionCompletion) -> Void
    ) {
        let accepted = client.acceptedItems(in: request, response: response)
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
            workQueue.addOperation {
                let loaded = DispatchSemaphore(value: 0)
                providerReference.provider.loadInPlaceFileRepresentation(
                    forTypeIdentifier: typeIdentifier
                ) { sourceURL, _, _ in
                    defer { loaded.signal() }
                    guard let sourceURL else {
                        accumulator.recordFailure(item.id)
                        return
                    }
                    let copied = DispatchSemaphore(value: 0)
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer { copied.signal() }
                        do {
                            accumulator.recordStaged(
                                try client.stage(
                                    sourceURL: sourceURL,
                                    item: item,
                                    requestID: request.id
                                )
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
