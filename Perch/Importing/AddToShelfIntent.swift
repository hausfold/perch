import AppIntents
import Foundation

/// The programmatic front door onto the shelf: Shortcuts, Spotlight, and
/// `shortcuts run` all resolve to this, funnelling into the same
/// `ShelfStore.importFileURLs` / `importData` a drag uses — same admission
/// cap, same staging pipeline, same "never touch the source" guarantee.
struct AddToShelfIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Perch Shelf"
    static let description = IntentDescription(
        "Copies one or more files onto the Perch shelf.",
        categoryName: "Shelf"
    )

    // `supportedTypeIdentifiers` (not `supportedContentTypes`, macOS 15+-only)
    // is the overload available at this project's macOS 14.0 floor.
    @Parameter(title: "Files", supportedTypeIdentifiers: ["public.item"])
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$files) to the shelf")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = AppRuntime.shared.store
        // `IntentFile.fileURL` is set whenever Shortcuts backed the value
        // with a real file (Finder selections, "Get File from Folder",
        // etc.) — those go through `importFileURLs`, same as a drag.
        // Anything handed over as in-memory `data` instead (built earlier in
        // a Shortcut, no file on disk to point at) goes through `importData`,
        // which writes straight into its own staging container — no
        // throwaway temp file for anyone to leak or clean up.
        var fileURLs: [URL] = []
        for file in files {
            if let fileURL = file.fileURL {
                fileURLs.append(fileURL)
            } else {
                store.importData(file.data, suggestedName: file.filename)
            }
        }
        if !fileURLs.isEmpty {
            store.importFileURLs(fileURLs)
        }
        return .result()
    }
}

struct PerchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddToShelfIntent(),
            phrases: [
                "Add to \(.applicationName)",
                "Add files to \(.applicationName)",
            ],
            shortTitle: "Add to Shelf",
            systemImageName: "tray.and.arrow.down"
        )
    }
}
