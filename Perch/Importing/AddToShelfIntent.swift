import AppIntents
import Foundation

/// The programmatic front door onto the shelf: Shortcuts, Spotlight, and
/// `shortcuts run` all resolve to this, funnelling into the same
/// `ShelfStore.importFileURLs` a drag uses — same admission cap, same
/// staging pipeline, same "never touch the source" guarantee.
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
        let urls = try files.map(Self.materialize)
        AppRuntime.shared.store.importFileURLs(urls)
        return .result()
    }

    /// `IntentFile.fileURL` is set whenever Shortcuts backed the value with a
    /// real file (Finder selections, "Get File from Folder", etc.) — that URL
    /// goes straight into `importFileURLs`, same as a drag. Anything handed
    /// over as in-memory `data` instead (an image built earlier in a
    /// Shortcut) has no source file to point at, so it's written to a
    /// throwaway temp file first; `stageFile` then copies it into staging
    /// exactly like every other import.
    private static func materialize(_ file: IntentFile) throws -> URL {
        if let fileURL = file.fileURL {
            return fileURL
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appending(path: file.filename)
        try file.data.write(to: temp)
        return temp
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
