import AppKit
import SwiftUI

struct FileDragSourceView: NSViewRepresentable {
    let urls: [URL]
    let onExportStarted: () -> Void
    let onExportEnded: () -> Void
    let onSuccessfulExport: () -> Void
    // Double-click to open. Optional: the drag-all stack handle reuses this
    // view purely to export, and has nothing single to open.
    var onOpen: (() -> Void)?

    func makeNSView(context: Context) -> DragSourceNSView {
        DragSourceNSView()
    }

    func updateNSView(_ nsView: DragSourceNSView, context: Context) {
        nsView.urls = urls
        nsView.onExportStarted = onExportStarted
        nsView.onExportEnded = onExportEnded
        nsView.onSuccessfulExport = onSuccessfulExport
        nsView.onOpen = onOpen
    }
}

final class DragSourceNSView: NSView, NSDraggingSource {
    var urls: [URL] = []
    var onExportStarted: (() -> Void)?
    var onExportEnded: (() -> Void)?
    var onSuccessfulExport: (() -> Void)?
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
        guard !startedSession, !urls.isEmpty else { return }
        startedSession = true
        onExportStarted?()

        let draggingItems = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 48, height: 48)
            let offset = CGFloat(min(index, 4)) * 3
            item.setDraggingFrame(
                CGRect(x: bounds.midX - 24 + offset, y: bounds.midY - 24 - offset, width: 48, height: 48),
                contents: icon
            )
            return item
        }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

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
        if operation.contains(.copy) {
            onSuccessfulExport?()
        }
        onExportEnded?()
        startedSession = false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override var acceptsFirstResponder: Bool { true }
}
