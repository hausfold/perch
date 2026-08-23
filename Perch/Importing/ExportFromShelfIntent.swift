import AppIntents
import Foundation

enum ExportFromShelfIntentError: LocalizedError {
    case itemsNoLongerOnShelf

    var errorDescription: String? {
        "None of the selected items are still on the shelf."
    }
}

/// The symmetric other half of `AddToShelfIntent`: hands staged items back
/// out to the rest of a Shortcut as real files. Reuses the exact
/// lift/hand-off transaction a drag-out to a terminal or editor already
/// goes through (`ShelfStore.liftForExport` + `handOff`) — the returned
/// `IntentFile`s point at the same staged bytes, which the shelf detaches
/// rather than deletes, because a Shortcut holding a file URL is no
/// different from an app that read a dropped file's path instead of asking
/// for the promise.
struct ExportFromShelfIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Files from Perch Shelf"
    static let description = IntentDescription(
        "Hands staged shelf items to the rest of the Shortcut. Unpinned items leave the shelf, the same as a drag-out; pinned items stay behind.",
        categoryName: "Shelf"
    )

    @Parameter(title: "Items")
    var items: [ShelfItemEntity]

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$items) from the shelf")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let store = AppRuntime.shared.store
        let ids = Set(items.map(\.id))
        let staged = store.items.filter { ids.contains($0.id) }
        let files: [IntentFile] = staged.compactMap { item in
            // Resolved, not the recorded path: a Shortcut is a plain-URL
            // destination that never reports back, so a stale URL here is
            // handed out and then detached with nothing able to undo it.
            guard let url = store.stagedURL(for: item) else { return nil }
            return IntentFile(fileURL: url, filename: item.displayName, type: item.contentType)
        }
        guard files.isEmpty == false || items.isEmpty else {
            throw ExportFromShelfIntentError.itemsNoLongerOnShelf
        }
        // This export never goes through the drag source, so it opens the
        // transaction itself — otherwise a verdict left over from an earlier
        // drag could silently suppress the lift while the Shortcut still gets
        // its file.
        store.beginExport(of: ids)
        store.liftForExport(ids)
        store.handOff(ids)
        return .result(value: files)
    }
}
