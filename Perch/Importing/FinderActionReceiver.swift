import Foundation

/// The containing-app half of the Finder Action mailbox. Polling is deliberate:
/// Apple provides no supported extension-to-containing-app call, Perch is
/// already a long-running menu-bar process, and a private Mach service would be
/// a larger permission surface than checking one App Group directory.
@MainActor
final class FinderActionReceiver {
    private let store: ShelfStore
    private let mailbox: FinderActionMailbox?
    private var loopTask: Task<Void, Never>?
    private var processing: Set<UUID> = []

    init(store: ShelfStore, mailbox: FinderActionMailbox? = try? FinderActionMailbox()) {
        self.store = store
        self.mailbox = mailbox
    }

    func start() {
        guard mailbox != nil, loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scanOnce()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Internal so the integration tests can drive one deterministic mailbox
    /// turn without sleeping; production uses the bounded loop above.
    func scanOnce(now: Date = Date()) async {
        guard let mailbox else { return }
        let snapshots: [FinderActionSnapshot]
        do {
            snapshots = try await Task.detached(priority: .utility) {
                try mailbox.snapshots()
            }.value
        } catch {
            return
        }

        for snapshot in snapshots where !processing.contains(snapshot.request.id) {
            if now.timeIntervalSince(snapshot.request.createdAt) >= FinderActionProtocol.abandonedAfter {
                let accepted = acceptedItems(in: snapshot)
                accepted.forEach(store.failFinderImport)
                try? await remove(snapshot.request.id, from: mailbox)
                continue
            }

            guard let response = snapshot.response else {
                let accepted = store.admitFinderItems(snapshot.request.items)
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try mailbox.writeResponse(
                            FinderActionResponse(acceptedItemIDs: accepted.map(\.id)),
                            for: snapshot.request.id
                        )
                    }.value
                } catch {
                    accepted.forEach(store.failFinderImport)
                    try? await remove(snapshot.request.id, from: mailbox)
                }
                continue
            }

            let acceptedIDs = Set(response.acceptedItemIDs)
            let accepted = snapshot.request.items.filter { acceptedIDs.contains($0.id) }
            store.resumeFinderItems(accepted)
            guard let completion = snapshot.completion else { continue }

            processing.insert(snapshot.request.id)
            let stagedByID = Dictionary(
                completion.stagedItems.map { ($0.id, $0.relativePath) },
                uniquingKeysWith: { first, _ in first }
            )
            for item in accepted {
                guard let relativePath = stagedByID[item.id] else {
                    store.failFinderImport(item)
                    continue
                }
                let url = await Task.detached(priority: .utility) {
                    guard let url = try? mailbox.stagedURL(
                        relativePath: relativePath,
                        requestID: snapshot.request.id
                    ), FileManager.default.fileExists(atPath: url.path)
                    else {
                        return nil as URL?
                    }
                    return url
                }.value
                guard let url else {
                    store.failFinderImport(item)
                    continue
                }
                await store.completeFinderImport(item, stagedAt: url)
            }
            try? await remove(snapshot.request.id, from: mailbox)
            processing.remove(snapshot.request.id)
        }
    }

    private func acceptedItems(in snapshot: FinderActionSnapshot) -> [FinderActionItem] {
        guard let response = snapshot.response else { return [] }
        let ids = Set(response.acceptedItemIDs)
        return snapshot.request.items.filter { ids.contains($0.id) }
    }

    private func remove(_ requestID: UUID, from mailbox: FinderActionMailbox) async throws {
        try await Task.detached(priority: .utility) {
            try mailbox.removeRequest(requestID)
        }.value
    }
}
