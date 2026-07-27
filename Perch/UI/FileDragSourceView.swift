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
struct ExportItem: Identifiable, Equatable {
    let id: UUID
    /// The staged source copy to read from.
    let url: URL
    /// UTI advertised to the destination.
    let fileType: String
    /// Name written at the destination.
    let fileName: String
}

struct FileDragSourceView: NSViewRepresentable {
    let items: [ExportItem]
    let onExportStarted: () -> Void
    let onExportEnded: () -> Void
    /// Fired on the main actor once a single item's destination copy concludes:
    /// `true` — the receiver has its own copy, the shelf may delete the staged
    /// one; `false` — cancelled / refused / failed, keep the item.
    let onItemExportFinished: (UUID, Bool) -> Void
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
    var onItemExportFinished: ((UUID, Bool) -> Void)?
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
            let provider = NSFilePromiseProvider(fileType: export.fileType, delegate: self)
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
        // the shelf every promised item finished *without* export so a collapsed
        // tile springs back. On a real .copy the per-item promise completions
        // below deliver the verdict instead; don't pre-empt them here.
        guard !operation.contains(.copy) else { return }
        for export in items {
            onItemExportFinished?(export.id, false)
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
        do {
            try FileManager.default.copyItem(at: export.url, to: url)
            completionHandler(nil)
            report(export.id, exported: true)
        } catch {
            completionHandler(error)
            report(export.id, exported: false)
        }
    }

    private nonisolated func report(_ id: UUID, exported: Bool) {
        Task { @MainActor [weak self] in
            self?.onItemExportFinished?(id, exported)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override var acceptsFirstResponder: Bool { true }
}
