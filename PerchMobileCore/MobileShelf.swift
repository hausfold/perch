import Foundation
import UniformTypeIdentifiers

/// The phone-side shelf: the same staging discipline as the Mac (a UUID
/// container per item, copies only, manifest of completed items), plus an
/// outbox recording which items still owe a delivery.
///
/// Both the app and the Share extension construct one of these over the same
/// App Group directory. Writes are atomic and `load()` reconciles from disk,
/// so the two processes converge even when a share lands while the app is
/// open.
final class MobileShelf: @unchecked Sendable {
    let repository: StagingRepository

    private let outboxURL: URL
    private let lock = NSLock()

    /// What still needs to happen to an item, or the receipt of what did.
    enum Delivery: Codable, Equatable, Sendable {
        case waiting
        case delivered(Date)
    }

    init() throws {
        repository = try StagingRepository(rootURL: MobileConfig.shelfRoot)
        outboxURL = MobileConfig.groupContainer.appending(path: "outbox.json")
    }

    // MARK: - Reading

    func items() -> [ShelfItem] {
        repository.load()
    }

    func deliveries() -> [UUID: Delivery] {
        (try? JSONDecoder().decode(
            [UUID: Delivery].self,
            from: Data(contentsOf: outboxURL)
        )) ?? [:]
    }

    /// Items still waiting to reach the Mac, oldest first.
    func waitingItems() -> [ShelfItem] {
        let deliveries = deliveries()
        return items().filter { deliveries[$0.id, default: .waiting] == .waiting }
    }

    // MARK: - Staging (what a share or an in-app add produces)

    /// Copies a file the system handed us into its own staged container.
    func stageFile(at sourceURL: URL, displayName: String? = nil) throws -> ShelfItem {
        let itemID = UUID()
        let container = try repository.allocateImportDirectory(id: itemID)
        let name = StagingRepository.safeFilename(displayName ?? sourceURL.lastPathComponent)
        let destination = container.appending(path: name)
        let partial = container.appending(path: ".\(itemID.uuidString).partial")
        do {
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if scoped { sourceURL.stopAccessingSecurityScopedResource() }
            }
            try FileManager.default.copyItem(at: sourceURL, to: partial)
            try FileManager.default.moveItem(at: partial, to: destination)
            let item = try repository.item(forStagedURL: destination, id: itemID)
            commit(item)
            return item
        } catch {
            try? FileManager.default.removeItem(at: container)
            throw error
        }
    }

    func stageData(_ data: Data, displayName: String) throws -> ShelfItem {
        let itemID = UUID()
        let container = try repository.allocateImportDirectory(id: itemID)
        let destination = container.appending(
            path: StagingRepository.safeFilename(displayName)
        )
        do {
            try data.write(to: destination, options: [.atomic])
            let item = try repository.item(forStagedURL: destination, id: itemID)
            commit(item)
            return item
        } catch {
            try? FileManager.default.removeItem(at: container)
            throw error
        }
    }

    func stageText(_ text: String) throws -> ShelfItem {
        try stageData(Data(text.utf8), displayName: "Text.txt")
    }

    /// A shared link becomes a `.webloc`, which the Mac shelf already knows
    /// how to show and Finder knows how to open.
    func stageLink(_ url: URL, title: String?) throws -> ShelfItem {
        let name = StagingRepository.safeFilename((title?.isEmpty == false ? title! : url.host() ?? "Link") + ".webloc")
        let plist: [String: String] = ["URL": url.absoluteString]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        return try stageData(data, displayName: name)
    }

    // MARK: - Outcomes

    func remove(_ item: ShelfItem) throws {
        try repository.remove(item)
        var current = items()
        current.removeAll { $0.id == item.id }
        try repository.persist(current)
        mutateOutbox { $0[item.id] = nil }
    }

    /// The Mac confirmed durable storage: the phone's copy has done its job.
    /// The bytes go; a dated receipt stays so the UI can say so.
    func markDelivered(_ itemID: UUID) {
        let current = items()
        if let item = current.first(where: { $0.id == itemID }) {
            try? repository.remove(item)
            try? repository.persist(current.filter { $0.id != itemID })
        }
        mutateOutbox { $0[itemID] = .delivered(Date()) }
    }

    /// Receipts older than a day stop being news; a waiting entry whose item
    /// no longer exists is a leftover and goes too.
    func pruneReceipts() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let known = Set(items().map(\.id))
        mutateOutbox { outbox in
            outbox = outbox.filter { entry in
                switch entry.value {
                case let .delivered(date):
                    date >= cutoff
                case .waiting:
                    known.contains(entry.key)
                }
            }
        }
    }

    // MARK: - Offers

    /// The wire offer for one staged item — including the digest the Mac will
    /// hold the arriving bytes to.
    ///
    /// The digest itself comes from `WireStreaming`, the same code the Mac uses
    /// to offer an item back to a phone. "The bytes are verified end to end" is
    /// only one fact if there is only one place that hashes them.
    func offer(for item: ShelfItem) throws -> OutgoingItem {
        guard let url = item.fileURL(inside: repository.rootURL) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try WireStreaming.offer(
            id: item.id,
            displayName: item.displayName,
            contentTypeIdentifier: item.contentTypeIdentifier,
            kindHint: item.kind.rawValue,
            fileURL: url
        )
    }

    // MARK: - Outbox file

    /// A freshly staged item enters the manifest at once, under its real ID.
    /// Leaving it for `load()`'s recovery scan would work — but recovery
    /// invents a fresh UUID, orphaning the outbox entry made here. `items()`
    /// itself may have just adopted this very file under such a fresh ID, so
    /// matching by path (not ID) is what keeps this from double-listing it.
    private func commit(_ item: ShelfItem) {
        var current = items().filter { $0.relativePath != item.relativePath }
        current.append(item)
        try? repository.persist(current)
        mutateOutbox { $0[item.id] = .waiting }
    }

    private func mutateOutbox(_ change: (inout [UUID: Delivery]) -> Void) {
        lock.withLock {
            var outbox = deliveries()
            change(&outbox)
            if let data = try? JSONEncoder().encode(outbox) {
                try? data.write(to: outboxURL, options: [.atomic])
            }
        }
    }
}
