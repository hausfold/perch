import Foundation

/// The app's half of the App Group mailbox — today the `perch` CLI is its only
/// sender, and the name predates that: a `PerchFinderAction` extension spoke it
/// too until 2026-08-23. The name stays because `FinderActionRequests` is an
/// on-disk path an *installed* copy of the tool writes to.
///
/// Three verbs arrive here. `add` is the four-step transaction the mailbox was
/// built for; `list` and `remove` are answered in one turn and copy nothing —
/// they exist so the command line can see the shelf it has been writing to,
/// and they are second clients of what the paired phone already asks for over
/// the wire, not new shelf behaviour.
///
/// Polling is deliberate: Perch is already a long-running menu-bar process, and
/// a private Mach service would be a larger permission surface than checking
/// one App Group directory. (It was also the only option while an extension was
/// a sender — Apple provides no supported extension-to-containing-app call.)
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
                // A read verb reserves nothing, so `acceptedItems` is empty for
                // one and this is simply the sweep that drops the directory.
                let accepted = acceptedItems(in: snapshot)
                accepted.forEach(store.failFinderImport)
                try? await remove(snapshot.request.id, from: mailbox)
                continue
            }

            switch snapshot.request.kind {
            case .add:
                await serveAdd(snapshot, mailbox: mailbox)
            case .list:
                await serveReadVerb(snapshot, mailbox: mailbox) { self.shelfEntries() }
            case .remove:
                await serveReadVerb(snapshot, mailbox: mailbox) {
                    self.removeFromShelf(snapshot.request.targetItemIDs)
                }
            case nil:
                // A verb from a newer sender than this build. Answering with no
                // entries at all is what tells it so; refusing to answer would
                // leave it waiting out its whole timeout for a shelf that is
                // right here.
                await serveReadVerb(snapshot, mailbox: mailbox) { nil }
            }
        }
    }

    // MARK: - add

    /// The four-step transaction: reserve, receipt, copy, adopt. Unchanged by
    /// the read verbs — it is only the body that used to be inline in the scan.
    private func serveAdd(_ snapshot: FinderActionSnapshot, mailbox: FinderActionMailbox) async {
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
            return
        }

        let acceptedIDs = Set(response.acceptedItemIDs)
        let accepted = snapshot.request.items.filter { acceptedIDs.contains($0.id) }
        store.resumeFinderItems(accepted)
        guard let completion = snapshot.completion else { return }

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

    // MARK: - list and remove

    /// A read verb's whole life. It is answered exactly once — the response on
    /// disk is what makes that idempotent across scans, which for `remove`
    /// means a second look never removes anything twice — and the transaction
    /// is dropped only once the sender has acknowledged reading the answer.
    private func serveReadVerb(
        _ snapshot: FinderActionSnapshot,
        mailbox: FinderActionMailbox,
        act: () -> [FinderActionEntry]?
    ) async {
        guard snapshot.response == nil else {
            guard snapshot.completion != nil else { return }
            try? await remove(snapshot.request.id, from: mailbox)
            return
        }

        // Acting first and answering second is the only honest order: an answer
        // written before the shelf changed could describe a removal that then
        // failed. A write that fails after the fact drops the transaction, and
        // the sender reports no shelf answered — which is true of this one.
        let response = FinderActionResponse(acceptedItemIDs: [], entries: act())
        do {
            try await Task.detached(priority: .userInitiated) {
                try mailbox.writeResponse(response, for: snapshot.request.id)
            }.value
        } catch {
            try? await remove(snapshot.request.id, from: mailbox)
        }
    }

    /// The shelf as a sender sees it: what the panel shows, in the panel's
    /// order. Items still being copied are deliberately absent — a pending
    /// transfer has no bytes to drag and no id worth removing yet.
    private func shelfEntries() -> [FinderActionEntry] {
        store.items.map(Self.entry)
    }

    /// Take the named items off the shelf — the same removal the shelf's own
    /// menu and a paired phone's swipe perform, pins included: naming an id is
    /// as deliberate as either. The answer is exactly what went, so a sender
    /// can tell which of its ids were already gone.
    private func removeFromShelf(_ itemIDs: [UUID]) -> [FinderActionEntry] {
        var removed: [FinderActionEntry] = []
        for id in itemIDs {
            guard let item = store.items.first(where: { $0.id == id }) else { continue }
            removed.append(Self.entry(item))
            store.remove(item)
        }
        return removed
    }

    private static func entry(_ item: ShelfItem) -> FinderActionEntry {
        FinderActionEntry(
            id: item.id,
            displayName: item.displayName,
            kind: item.kind.rawValue,
            contentTypeIdentifier: item.contentTypeIdentifier,
            byteCount: item.byteCount,
            addedAt: item.addedAt,
            isPinned: item.isPinned
        )
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
