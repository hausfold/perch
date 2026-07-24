import AppKit
import SwiftUI

@MainActor
final class ShelfPanelController: NSObject {
    let screenID: String

    private let panel: ShelfPanel
    private let geometry: ShelfGeometry
    private let viewState: ShelfPanelState
    private var collapseTask: Task<Void, Never>?

    init(
        screen: NSScreen,
        store: ShelfStore,
        settings: AppSettings,
        dropHandler: ShelfDropHandler
    ) {
        screenID = screen.morselIdentifier
        geometry = ShelfGeometry(screen: ScreenDescriptor(screen: screen))
        viewState = ShelfPanelState(hasCameraHousing: geometry.hasCameraHousing)
        panel = ShelfPanel(
            contentRect: geometry.collapsedFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        super.init()

        let rootView = ShelfPanelView(
            store: store,
            settings: settings,
            state: viewState,
            onExpand: { [weak self] in self?.expand() },
            onCollapse: { [weak self] in self?.scheduleCollapse() }
        )
        let host = ShelfHostingView(rootView: rootView, dropHandler: dropHandler)
        host.onDragEntered = { [weak self] in
            self?.viewState.isDropActive = true
            self?.expand()
        }
        host.onDragExited = { [weak self] in
            self?.viewState.isDropActive = false
            self?.scheduleCollapse(delay: .seconds(0.8))
        }
        host.onDropCompleted = { [weak self] in
            self?.viewState.isDropActive = false
            self?.scheduleCollapse(delay: .seconds(0.8))
        }
        host.onPointerEntered = { [weak self] in
            guard settings.expandOnPointerHover else { return }
            self?.expand()
        }
        host.onPointerExited = { [weak self] in self?.scheduleCollapse() }

        panel.contentView = host
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.animationBehavior = .none
        panel.orderFrontRegardless()
    }

    func expand() {
        collapseTask?.cancel()
        guard !viewState.isExpanded else { return }
        viewState.isExpanded = true
        panel.hasShadow = true
        animate(to: geometry.expandedFrame, duration: 0.28)
    }

    func collapse() {
        collapseTask?.cancel()
        guard viewState.isExpanded, !viewState.isDropActive else { return }
        viewState.isExpanded = false
        panel.hasShadow = false
        animate(to: geometry.collapsedFrame, duration: 0.24)
    }

    func close() {
        collapseTask?.cancel()
        panel.orderOut(nil)
    }

    private func scheduleCollapse(delay: Duration = .seconds(1.1)) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.collapse()
        }
    }

    private func animate(to frame: CGRect, duration: TimeInterval) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.22,
                0.9,
                0.24,
                1
            )
            panel.animator().setFrame(frame, display: true)
        }
    }
}

private final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ShelfPanelState: ObservableObject {
    @Published var isExpanded = false
    @Published var isDropActive = false
    let hasCameraHousing: Bool

    init(hasCameraHousing: Bool) {
        self.hasCameraHousing = hasCameraHousing
    }
}

@MainActor
final class ShelfHostingView<Content: View>: NSHostingView<Content> {
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    var onDropCompleted: (() -> Void)?
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?

    private let dropHandler: ShelfDropHandler
    private var trackingAreaReference: NSTrackingArea?

    init(rootView: Content, dropHandler: ShelfDropHandler) {
        self.dropHandler = dropHandler
        super.init(rootView: rootView)
        registerForDraggedTypes(dropHandler.registeredTypes)
    }

    @available(*, unavailable)
    required init(rootView: Content) {
        fatalError("Use init(rootView:dropHandler:)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(tracking)
        trackingAreaReference = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onPointerExited?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dropHandler.canAccept(sender) else { return [] }
        onDragEntered?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHandler.canAccept(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExited?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHandler.canAccept(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let accepted = dropHandler.accept(sender)
        onDropCompleted?()
        return accepted
    }
}
