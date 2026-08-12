import AppIntents
import Foundation

/// The noun Shortcuts and Spotlight can hold, search, and pass between
/// intents. Deliberately thin — id, name, kind, timestamp for display and
/// sorting only — because it's a live view onto `ShelfStore.items`, not a
/// copy of its own; anything that needs the staged bytes re-reads the real
/// `ShelfItem` from the store by `id`.
struct ShelfItemEntity: AppEntity {
    let id: UUID
    let name: String
    let kind: ShelfItem.Kind
    let addedAt: Date

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Shelf Item"
    static let defaultQuery = ShelfItemEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(kind.rawValue.capitalized)")
    }

    init(_ item: ShelfItem) {
        id = item.id
        name = item.displayName
        kind = item.kind
        addedAt = item.addedAt
    }
}

struct ShelfItemEntityQuery: EntityQuery, EnumerableEntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ShelfItemEntity] {
        AppRuntime.shared.store.items
            .filter { identifiers.contains($0.id) }
            .map(ShelfItemEntity.init)
    }

    @MainActor
    func allEntities() async throws -> [ShelfItemEntity] {
        AppRuntime.shared.store.items.map(ShelfItemEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ShelfItemEntity] {
        try await allEntities()
    }
}
