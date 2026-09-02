import AppKit
import SwiftUI

@MainActor
final class ShelfPanelController: NSObject {
    let screenID: String

    private let panel: ShelfPanel
    private let geometry: ShelfGeometry
    private let viewState: ShelfPanelState
    private let theme: ShelfTheme
    private weak var store: ShelfStore?
    private var collapseTask: Task<Void, Never>?
    // Set by "Hide": keeps the shelf dismissed on hover until the pointer has
    // left the target area and returned — so the user can reach menu-bar /
    // sketchybar items beside the notch without the shelf popping back open.
    private var hoverSuppressed = false

    init(
        screen: NSScreen,
        store: ShelfStore,
        theme: ShelfTheme,
        dropHandler: ShelfDropHandler
    ) {
        screenID = screen.perchIdentifier
        self.theme = theme
        self.store = store
        geometry = ShelfGeometry(screen: ScreenDescriptor(screen: screen))
        viewState = ShelfPanelState(
            hasCameraHousing: geometry.hasCameraHousing,
            expandedContentWidth: geometry.expandedContentWidth,
            topEdgeDepth: geometry.topEdgeDepth
        )
        // `screen: nil`, deliberately. `ShelfGeometry` computes its frames in
        // *global* screen coordinates (as does the `expandedFrame.contains(
        // NSEvent.mouseLocation)` check in `scheduleCollapse`), and the
        // `screen:` parameter documents `contentRect` as relative to that
        // screen's lower-left corner — so passing both applies the screen
        // origin twice. On the zero-origin display the error is nil and it
        // looks fine; on any secondary display the panel lands one screen
        // origin away, which is why "show on every display" produced no
        // reachable drop target there (#13).
        panel = ShelfPanel(
            contentRect: geometry.collapsedFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: nil
        )
        super.init()

        // Fires after the drag view — and often this panel's hosting view with
        // it — is gone, so the store is reached from here rather than from the
        // SwiftUI closures.
        viewState.onExportHandOff = { [weak store] ids in
            store?.handOff(ids)
        }

        let rootView = ShelfPanelView(
            store: store,
            theme: theme,
            state: viewState,
            onExpand: { [weak self] in self?.expand() },
            onHide: { [weak self] in self?.hide() }
        )
        let host = ShelfHostingView(rootView: rootView, dropHandler: dropHandler)
        host.hoverTriggerWidth = geometry.hoverTriggerWidth
        host.hoverTriggerHeight = geometry.hoverTriggerHeight
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
            guard let self else { return }
            // Suppressed by a prior "Hide" until the pointer leaves and returns.
            guard !self.hoverSuppressed else { return }
            // Passive hover only reveals the shelf when there is something to
            // grab back out. An empty shelf is opened by a drag, not a hover.
            guard !store.items.isEmpty || !store.pendingTransfers.isEmpty else { return }
            self.expand()
        }
        host.onPointerExited = { [weak self] in
            guard let self else { return }
            // Leaving the area re-arms hover: a later return may open again.
            self.hoverSuppressed = false
            self.scheduleCollapse(delay: .seconds(0.12))
        }

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
        // Cheapest moment to notice haus changed underneath us: the panel is
        // about to become visible and nothing is mid-drag. Two small file reads.
        theme.refresh()
        // Same moment, same reason: someone may have renamed a staged file in
        // Finder since the shelf was last up, and the tile has to follow it
        // before it can be grabbed. One `stat` per item.
        store?.refreshStagedNames()
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

    /// Dismiss now and stay dismissed on hover until the pointer leaves the
    /// target area and returns (see `hoverSuppressed`).
    func hide() {
        hoverSuppressed = true
        viewState.isDropActive = false
        collapse()
    }

    func setArmed(_ armed: Bool) {
        guard viewState.isArmed != armed else { return }
        viewState.isArmed = armed
    }

    private func scheduleCollapse(delay: Duration = .seconds(1.1)) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // A frame change during expand emits a spurious mouseExited even
            // though the pointer is still over the shelf. Check against the
            // stable expanded target frame (not the live, mid-animation panel
            // frame) so a fast move into the target never flickers.
            guard !self.geometry.expandedFrame.contains(NSEvent.mouseLocation) else { return }
            self.collapse()
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
    // True while a mouse button is held anywhere on the system — i.e. a drag
    // could be in progress. The collapsed catch zone only renders its (faint,
    // hit-testable) fill while armed, so an idle shelf is fully transparent.
    @Published var isArmed = false
    // IDs of items currently being dragged out. Such a tile collapses to zero
    // width (neighbours slide in) but stays mounted so its drag source lives to
    // deliver the drop result: a successful copy removes the item for real, a
    // cancel/drop-back-on-shelf springs it back. Purely ephemeral drag UI state
    // — never persisted; the ShelfItem stays valid throughout.
    @Published var draggingOutIDs: Set<UUID> = []
    let hasCameraHousing: Bool
    // Width of the visible glass shelf, centered inside the wider (catch-zone
    // width) window. See ShelfGeometry.expandedContentWidth.
    let expandedContentWidth: CGFloat
    // Top-edge geometry; see ShelfGeometry. Used to hang the collapsed ShelfEmber
    // under the housing (or the menu bar, on a notchless display).
    let topEdgeDepth: CGFloat

    // Items whose destination engaged the file promise. Their verdict is coming
    // however long the copy takes, so the grace timer must not touch them.
    private var promiseEngagedIDs: Set<UUID> = []
    private var exportGraceTask: Task<Void, Never>?

    /// Called with the items a drag left unaccounted for: nothing engaged their
    /// promise and nothing reported, so a destination read the staged file URL
    /// directly. They are already off the shelf; this settles their bytes.
    var onExportHandOff: ((Set<UUID>) -> Void)?

    init(
        hasCameraHousing: Bool,
        expandedContentWidth: CGFloat,
        topEdgeDepth: CGFloat = 0
    ) {
        self.hasCameraHousing = hasCameraHousing
        self.expandedContentWidth = expandedContentWidth
        self.topEdgeDepth = topEdgeDepth
    }

    /// A drag ended on a `.copy`: give the destination a moment to engage the
    /// promise, then hand off whatever it never asked for. Invisible either way
    /// — the items are lifted the instant the drop is accepted; this only
    /// decides whether their staged bytes are deleted or detached.
    ///
    /// The timer lives here rather than on the drag source because the panel
    /// hides as the drag leaves the notch, tearing that view (and any timer it
    /// held) down mid-flight; this state object outlives it.
    func startExportGrace(after grace: Duration = .seconds(1)) {
        exportGraceTask?.cancel()
        exportGraceTask = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self else { return }
            let unaccounted = self.draggingOutIDs.subtracting(self.promiseEngagedIDs)
            guard !unaccounted.isEmpty else { return }
            self.draggingOutIDs.subtract(unaccounted)
            self.onExportHandOff?(unaccounted)
        }
    }

    /// A new drag started — its tiles stay collapsed until this drag resolves.
    func beginExport(of ids: Set<UUID>) {
        exportGraceTask?.cancel()
        exportGraceTask = nil
        promiseEngagedIDs.subtract(ids)
        draggingOutIDs.formUnion(ids)
    }

    func markPromiseEngaged(_ id: UUID) {
        promiseEngagedIDs.insert(id)
    }

    /// A drag-out resolved for one item, either way — it is no longer collapsed
    /// and no longer waiting on a promise.
    func finishExport(of id: UUID) {
        promiseEngagedIDs.remove(id)
        draggingOutIDs.remove(id)
    }
}

@MainActor
final class ShelfHostingView<Content: View>: NSHostingView<Content> {
    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    var onDropCompleted: (() -> Void)?
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?

    // Width of the centered hover-trigger band; nil (or ≥ bounds.width) means
    // the whole view triggers, as before. See ShelfGeometry.hoverTriggerWidth.
    var hoverTriggerWidth: CGFloat? {
        didSet { updateTrackingAreas() }
    }

    // Height of the hover band, measured down from the view's top edge; nil
    // (or ≥ bounds.height) means the full height triggers.
    var hoverTriggerHeight: CGFloat? {
        didSet { updateTrackingAreas() }
    }

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
        // Deliberately not .inVisibleRect: that option ignores whatever rect
        // is passed and always tracks the view's full visible bounds, which
        // is exactly the wide drag-catch band this hover band must stay
        // narrower than. This override already fires on bounds changes, so a
        // plain rect kept in sync here is enough.
        let tracking = NSTrackingArea(
            rect: hoverRect,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(tracking)
        trackingAreaReference = tracking
        super.updateTrackingAreas()
    }

    /// Centered sub-rect of `bounds` used for hover-to-expand. See
    /// `hoverTriggerWidth` and `ShelfHoverRegion`.
    private var hoverRect: NSRect {
        ShelfHoverRegion.rect(
            in: bounds,
            width: hoverTriggerWidth,
            height: hoverTriggerHeight,
            isFlipped: isFlipped
        )
    }

    /// Enter/exit edges for the passive-hover trigger. See `ShelfHoverGate`.
    ///
    /// The trigger cannot key off which tracking area fired: `NSHostingView`
    /// installs its own full-bounds area (options `mouseEnteredAndExited |
    /// mouseMoved | activeAlways | inVisibleRect`) with *this* view as owner as
    /// soon as the SwiftUI tree uses `.onHover`, so these overrides run for the
    /// entire wide drag-catch band as well as for the narrow band installed
    /// above. That is why narrowing `hoverTriggerWidth` twice (#55, #78)
    /// changed nothing: the geometry was already right and the trigger was not
    /// reading it. Hit-test the pointer instead.
    private var hoverGate = ShelfHoverGate()

    private func reportHover(_ signal: ShelfHoverGate.Signal, for event: NSEvent) {
        let inside = hoverRect.contains(convert(event.locationInWindow, from: nil))
        switch hoverGate.update(signal, isInBand: inside) {
        case .entered: onPointerEntered?()
        case .exited: onPointerExited?()
        case .none: break
        }
    }

    override func mouseEntered(with event: NSEvent) {
        reportHover(.sample, for: event)
    }

    override func mouseExited(with event: NSEvent) {
        // Always forwarded, never edge-gated: this is the only signal that the
        // pointer left the panel, and `scheduleCollapse` is the only passive
        // path back to a collapsed shelf. Gating it on "was in the band" leaves
        // a shelf the user hovered open, then moved down into, expanded
        // forever. The collapse it schedules re-checks the live pointer
        // location, so an exit reported early is harmless.
        reportHover(.left, for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // Crossing from the wide band into the narrow one does fire our own
        // area's `mouseEntered`, but a fast sweep can land the first event a
        // point or two outside it. Moves keep the gate honest whenever the
        // hosting view's own `mouseMoved` area exists; without it, enter/exit
        // alone are already exact, because then ours is the only area.
        reportHover(.sample, for: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isOwnExportDrag(sender), dropHandler.canAccept(sender) else { return [] }
        onDragEntered?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        !isOwnExportDrag(sender) && dropHandler.canAccept(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExited?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !isOwnExportDrag(sender) && dropHandler.canAccept(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !isOwnExportDrag(sender) else { return false }
        let accepted = dropHandler.accept(sender)
        onDropCompleted?()
        return accepted
    }

    /// True when this drag session originated from the shelf's own export view.
    /// Dropping items straight back onto any shelf panel must not re-import them
    /// as duplicates — the copies are already staged. Duplicates are only ever
    /// created by dragging the same file in from outside (a nil/foreign source).
    private func isOwnExportDrag(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingSource is DragSourceNSView
    }
}
