import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One staged file to vend out of the shelf by *file promise*.
///
/// Exporting used to advertise the staged URL directly, then delete that file
/// the instant the drag ended. But the receiver (e.g. Finder) copies the file
/// asynchronously, so deleting on drag-end raced its in-flight copy — surfacing
/// as "unexpected error -8058" and losing the item anyway. A promise inverts
/// this: the destination asks *us* to write the file into its chosen location,
/// and its completion handler tells us when — and whether — that copy finished.
/// Only a confirmed copy removes the item; a failed or cancelled drop keeps it.
///
/// The staged URL rides along on the same pasteboard (see
/// `ExportPromiseProvider`) so receivers that don't speak promises can still
/// take the drop. Those never report anything, so the shelf hands the item off
/// on a timer instead — see `ShelfStore.handOff`.
struct ExportItem: Identifiable, Equatable {
    let id: UUID
    /// The staged source copy to read from.
    let url: URL
    /// UTI advertised to the destination.
    let fileType: String
    /// Name written at the destination.
    let fileName: String
}

/// A file promise that *also* advertises the staged file URL.
///
/// A bare `NSFilePromiseProvider` only ever puts promise types on the drag
/// pasteboard, and a receiver that never learned to consume promises — every
/// terminal (Ghostty, Terminal.app), most text editors, browser file inputs —
/// then sees nothing it can take, so the drag reads as un-droppable and the
/// cursor never shows a drop hint. Appending `public.file-url` (after the
/// promise types, so promise-aware receivers still prefer the promise) makes
/// those receivers accept the drag and paste/read the staged path.
final class ExportPromiseProvider: NSFilePromiseProvider {
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.fileURL]
    }

    override func writingOptions(
        forType type: NSPasteboard.PasteboardType,
        pasteboard: NSPasteboard
    ) -> NSPasteboard.WritingOptions {
        // The URL is known up front — write it eagerly. Only the promise types
        // are lazily fulfilled.
        type == .fileURL ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        guard type == .fileURL, let export = userInfo as? ExportItem else {
            return super.pasteboardPropertyList(forType: type)
        }
        return (export.url as NSURL).pasteboardPropertyList(forType: .fileURL)
    }
}

/// What became of one item in a drag-out.
enum ExportOutcome {
    /// The destination asked us to fulfil its promise — the copy is underway.
    /// Only a receiver that speaks promises ever gets here, and its verdict
    /// (`copied` / `failed`) always follows, however long the copy takes.
    case promiseStarted
    /// The destination holds its own copy. The staged one may go.
    case copied
    /// Cancelled, refused, or the copy failed. The item stays on the shelf.
    case failed
}

struct FileDragSourceView: NSViewRepresentable {
    let items: [ExportItem]
    let onExportStarted: () -> Void
    let onExportEnded: () -> Void
    /// Fired on the main actor as a single item's export progresses.
    let onItemExportFinished: (UUID, ExportOutcome) -> Void
    // Double-click to open. Optional: the drag-all stack handle reuses this
    // view purely to export, and has nothing single to open.
    var onOpen: (() -> Void)?

    func makeNSView(context: Context) -> DragSourceNSView {
        DragSourceNSView()
    }

    func updateNSView(_ nsView: DragSourceNSView, context: Context) {
        nsView.items = items
        nsView.onExportStarted = onExportStarted
        nsView.onExportEnded = onExportEnded
        nsView.onItemExportFinished = onItemExportFinished
        nsView.onOpen = onOpen
    }
}

final class DragSourceNSView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    var items: [ExportItem] = []
    var onExportStarted: (() -> Void)?
    var onExportEnded: (() -> Void)?
    var onItemExportFinished: ((UUID, ExportOutcome) -> Void)?
    var onOpen: (() -> Void)?

    private var startedSession = false

    override func mouseDown(with event: NSEvent) {
        startedSession = false
    }

    override func mouseUp(with event: NSEvent) {
        // A drag consumes its own mouseUp via the dragging session, so reaching
        // here means the click stayed put. Open on the second click of a
        // double-click; single clicks do nothing (a tile is grab-or-open only).
        guard !startedSession, event.clickCount == 2 else { return }
        onOpen?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !startedSession, !items.isEmpty else { return }
        startedSession = true
        onExportStarted?()

        let draggingItems = items.enumerated().map { index, export -> NSDraggingItem in
            let provider = ExportPromiseProvider(fileType: export.fileType, delegate: self)
            provider.userInfo = export
            let dragItem = NSDraggingItem(pasteboardWriter: provider)
            let icon = NSWorkspace.shared.icon(forFile: export.url.path)
            icon.size = NSSize(width: 48, height: 48)
            let offset = CGFloat(min(index, 4)) * 3
            dragItem.setDraggingFrame(
                CGRect(x: bounds.midX - 24 + offset, y: bounds.midY - 24 - offset, width: 48, height: 48),
                contents: icon
            )
            return dragItem
        }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        startedSession = false
        onExportEnded?()
        // No copy will occur — cancel, Escape, an invalid target, or a drop
        // straight back onto the shelf (refused by the own-export guard). Tell
        // the shelf every promised item failed so a collapsed tile springs back.
        //
        // On a real .copy, don't pre-empt: a promise-aware receiver reports for
        // itself below, and a receiver that took the plain file URL instead
        // reports nothing at all — the shelf's grace timer hands those items off.
        // See ShelfPanelState.startExportGrace.
        guard !operation.contains(.copy) else { return }
        for export in items {
            report(export.id, .failed)
        }
    }

    // MARK: NSFilePromiseProviderDelegate

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        (filePromiseProvider.userInfo as? ExportItem)?.fileName ?? "file"
    }

    nonisolated func operationQueue(
        for filePromiseProvider: NSFilePromiseProvider
    ) -> OperationQueue {
        // Promise fulfilment copies the staged file to the destination; that
        // copy must stay off the main actor (architecture invariant: the main
        // actor never performs a potentially blocking copy).
        let queue = OperationQueue()
        queue.name = "com.nebelhaus.perch.export"
        queue.qualityOfService = .userInitiated
        return queue
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let export = filePromiseProvider.userInfo as? ExportItem else {
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }
        // Tell the shelf a promise-aware receiver has engaged before the copy
        // starts: that item now waits for the verdict below however long the
        // copy runs, instead of being handed off as a plain-URL drop.
        report(export.id, .promiseStarted)
        do {
            try FileManager.default.copyItem(at: export.url, to: url)
            completionHandler(nil)
            report(export.id, .copied)
        } catch {
            completionHandler(error)
            report(export.id, .failed)
        }
    }

    private nonisolated func report(_ id: UUID, _ outcome: ExportOutcome) {
        Task { @MainActor [weak self] in
            self?.onItemExportFinished?(id, outcome)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override var acceptsFirstResponder: Bool { true }
}
