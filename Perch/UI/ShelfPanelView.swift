import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfPanelView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: ShelfPanelState

    let onExpand: () -> Void
    let onHide: () -> Void

    var body: some View {
        ZStack {
            if state.isExpanded {
                expandedShelf
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            } else {
                collapsedShelf
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.24, extraBounce: 0.08), value: state.isExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Perch file shelf")
    }

    private var collapsedShelf: some View {
        // No synthetic notch, on any display: the collapsed shelf draws nothing
        // but the ember, hung under the camera housing where there is one and
        // under the menu bar where there isn't (see ShelfGeometry.topEdgeDepth).
        // An empty shelf shows nothing at all.
        //
        // The whole collapsed frame is made hit-testable with contentShape even
        // when it draws nothing: without it, SwiftUI's Color.clear reports no
        // hit, NSHostingView.hitTest returns nil, and AppKit never routes an
        // incoming drag here — so draggingEntered would never fire.
        ZStack(alignment: .top) {
            catchZone
            if hasContent {
                ShelfEmber(
                    itemCount: store.items.count,
                    isStaging: !store.pendingTransfers.isEmpty,
                    isArmed: state.isArmed,
                    housingWidth: state.housingWidth
                )
                // Clear of the top-edge furniture by a hair, so the ember hangs
                // off it instead of being clipped behind it.
                .padding(.top, state.topEdgeDepth + 4)
                .transition(.opacity.combined(with: .scale(scale: 0.5)))
            }
        }
        .animation(.snappy(duration: 0.3, extraBounce: 0.1), value: hasContent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
    }

    // A non-opaque window derives its draggable/clickable region from rendered
    // alpha: fully transparent pixels are treated as click-through and never
    // receive draggingEntered. So while a drag might be underway (armed) the
    // catch zone is filled at the lowest alpha that still registers as a drop
    // target; when idle it is fully transparent — nothing to see, nothing to
    // catch (bar the ember itself, whose lit pixels are their own tap target).
    private var catchZone: some View {
        Color.black.opacity(state.isArmed ? catchZoneAlpha : 0)
    }

    /// Lowest fill alpha that keeps the collapsed window a valid drop target.
    private let catchZoneAlpha = 0.005

    // Square top corners so the panel reads as emerging from the top of the
    // screen; only the bottom corners are rounded.
    private static let shelfCornerRadius: CGFloat = 24
    private var shelfShape: UnevenRoundedRectangle {
        .rect(bottomLeadingRadius: Self.shelfCornerRadius, bottomTrailingRadius: Self.shelfCornerRadius)
    }

    private var expandedShelf: some View {
        ZStack {
            // cornerRadius 0: the glass is a plain rectangle; compositingGroup()
            // flattens it with the tint so the shelfShape clip actually rounds
            // the bottom (clipShape alone does not reshape an NSGlassEffectView).
            GlassBackground(cornerRadius: 0)
            Color.black.opacity(0.42)

            content
                .padding(.horizontal, 18)
                .padding(.top, state.hasCameraHousing ? 40 : 16)
                .padding(.bottom, 16)
        }
        .compositingGroup()
        .clipShape(shelfShape)
        .overlay {
            // Sides + bottom only — no line across the top, so the panel reads
            // as continuous with the screen edge it grows from.
            ShelfBorderShape(radius: Self.shelfCornerRadius)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        // The window spans the full catch-zone width so expand only grows
        // downward; the glass is trimmed to its reading width and centered,
        // leaving transparent (click-through) margins on either side.
        .frame(maxWidth: state.expandedContentWidth)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            if let error = store.latestError {
                errorBanner(error)
                    .padding(10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder private var content: some View {
        if hasContent {
            VStack(spacing: 10) {
                header
                itemStrip
            }
        } else {
            emptyState
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(itemCountDescription)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 8)
            if store.items.count > 1 {
                dragAllHandle
            }
            if !store.items.isEmpty {
                ShelfHeaderButton(
                    title: "Clear",
                    systemImage: "trash",
                    tint: Color(red: 1, green: 0.42, blue: 0.42),
                    action: { store.clear() }
                )
                .accessibilityHint("Deletes every staged copy")
            }
            ShelfHeaderButton(
                title: "Hide",
                systemImage: "chevron.up",
                action: onHide
            )
            .accessibilityHint("Dismisses the shelf until you move away and return")
        }
    }

    // Grabs the whole shelf at once — the popular flow. Individual tiles drag
    // only themselves; this stack handle is the "take everything" affordance,
    // shown only when there is more than one item (with one, the tile is it).
    private var dragAllHandle: some View {
        HStack(spacing: 5) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.subheadline.weight(.semibold))
            Text("Drag all \(store.items.count)")
                .font(.body.weight(.medium))
        }
        .foregroundStyle(.white.opacity(0.82))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.white.opacity(0.08)))
        .contentShape(Capsule())
        .overlay {
            FileDragSourceView(
                items: store.items.compactMap(exportItem(for:)),
                onExportStarted: {
                    state.isDropActive = true
                    // Collapse every tile at once; the strip empties as the
                    // stack lifts off. Each item leaves for real only once its
                    // destination is accounted for; a refused drop springs back.
                    state.beginExport(of: Set(store.items.map(\.id)))
                },
                onExportEnded: {
                    state.isDropActive = false
                    state.startExportGrace()
                },
                onItemExportFinished: finishExport
            )
            .accessibilityLabel("Drag all \(store.items.count) items")
        }
    }

    /// Resolves a shelf item to something the drag source can vend by promise,
    /// or nil when its staged copy can't be located.
    private func exportItem(for item: ShelfItem) -> ExportItem? {
        guard let url = item.fileURL(inside: store.repository.rootURL) else { return nil }
        let fileType = item.contentTypeIdentifier
            ?? (item.kind == .folder ? UTType.folder.identifier : UTType.data.identifier)
        return ExportItem(id: item.id, url: url, fileType: fileType, fileName: item.displayName)
    }

    /// One dragged-out item's export progressed. The item leaves the shelf the
    /// moment a destination accepts it and only comes back if that destination
    /// then refuses it — never the other way round, which was the -8058
    /// data-loss bug. What becomes of the staged bytes is settled last: deleted
    /// on a confirmed copy, detached by the grace timer for a destination that
    /// took the plain file URL and reports nothing.
    private func finishExport(_ id: UUID, outcome: ExportOutcome) {
        switch outcome {
        case .accepted:
            store.liftForExport([id])
        case .promiseStarted:
            state.markPromiseEngaged(id)
        case .failed:
            state.finishExport(of: id)
            store.returnToShelf(id)
        case .copied:
            state.finishExport(of: id)
            store.confirmCopied(id)
        }
    }

    private var emptyState: some View {
        // An empty shelf only ever expands because a drag reached it (passive
        // hover is gated on having items), so this doubles as the "drop here"
        // affordance shown while a file is held over the target.
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 28, weight: .light))
            Text("Drop here")
                .font(.title3.weight(.semibold))
        }
        .foregroundStyle(.white.opacity(state.isDropActive ? 0.9 : 0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    .white.opacity(state.isDropActive ? 0.35 : 0.12),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
                .padding(6)
        }
        .accessibilityLabel("Drop files here")
    }

    private var hasContent: Bool {
        !store.items.isEmpty || !store.pendingTransfers.isEmpty
    }

    private var itemStrip: some View {
        // spacing 0: the inter-tile gap lives inside each FileTile's horizontal
        // padding so it can collapse to zero along with the tile's width when
        // that tile is dragged out — otherwise the fixed HStack spacing would
        // leave a stranded gap where the exiting tile used to be.
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(store.items) { item in
                    FileTile(
                        item: item,
                        fileURL: item.fileURL(inside: store.repository.rootURL),
                        exportItems: exportItem(for: item).map { [$0] } ?? [],
                        isExiting: state.draggingOutIDs.contains(item.id),
                        onReveal: { store.reveal(item) },
                        onRemove: { withAnimation(Self.reflow) { store.remove(item) } },
                        onOpen: { store.open(item) },
                        onExportStarted: {
                            state.isDropActive = true
                            state.beginExport(of: [item.id])
                        },
                        onExportEnded: {
                            state.isDropActive = false
                            state.startExportGrace()
                        },
                        onItemExportFinished: finishExport
                    )
                }
                ForEach(store.pendingTransfers) { transfer in
                    PendingTile(transfer: transfer)
                }
            }
            .padding(.vertical, 3)
            .animation(Self.reflow, value: state.draggingOutIDs)
            .animation(Self.reflow, value: store.items)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity)
    }

    /// Shared spring for tiles sliding in/out so a drag-out reflows the strip
    /// instead of snap-shrinking it.
    private static let reflow = Animation.snappy(duration: 0.32, extraBounce: 0.12)

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(error)
                .lineLimit(2)
            Spacer()
            Button {
                store.latestError = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(10)
        .background(.red.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
    }

    private var itemCountDescription: String {
        let count = store.items.count
        return count == 1 ? "1 item" : "\(count) items"
    }
}

/// Outline for the shelf: down the left side, around both bottom corners, up
/// the right side — deliberately omitting the top edge so there is no top
/// border where the panel meets the screen edge.
private struct ShelfBorderShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        // Inset by half a point so the 1pt stroke sits fully inside the clip.
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(radius, r.height)
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: r.minX + radius, y: r.maxY),
            control: CGPoint(x: r.minX, y: r.maxY)
        )
        path.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
        path.addQuadCurve(
            to: CGPoint(x: r.maxX, y: r.maxY - radius),
            control: CGPoint(x: r.maxX, y: r.maxY)
        )
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return path
    }
}

/// A readable, comfortably-tappable pill button for the shelf header.
private struct ShelfHeaderButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .white
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                Text(title)
                    .font(.body.weight(.medium))
            }
            .foregroundStyle(tint.opacity(hovering ? 1 : 0.82))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(.white.opacity(hovering ? 0.16 : 0.08))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}

private struct FileTile: View {
    let item: ShelfItem
    let fileURL: URL?
    let exportItems: [ExportItem]
    // While true the tile is mid drag-out: it collapses to zero width so the
    // neighbouring tiles slide in, but stays mounted so its FileDragSourceView
    // survives to receive the drop result. See ShelfPanelState.draggingOutIDs.
    var isExiting: Bool = false
    let onReveal: () -> Void
    let onRemove: () -> Void
    let onOpen: () -> Void
    let onExportStarted: () -> Void
    let onExportEnded: () -> Void
    let onItemExportFinished: (UUID, ExportOutcome) -> Void

    // Half the inter-tile gap on each side sums to the strip's 14pt spacing;
    // living inside the tile means it collapses to zero with the tile on exit.
    private static let sideInset: CGFloat = 7

    var body: some View {
        card
            .padding(.horizontal, isExiting ? 0 : Self.sideInset)
            .frame(width: isExiting ? 0 : nil)
            .scaleEffect(isExiting ? 0.6 : 1, anchor: .center)
            .opacity(isExiting ? 0 : 1)
            // Contain the shrinking tile so it never bleeds over its neighbours,
            // but only while exiting — at rest the clip region is expanded so the
            // remove badge can still overhang the corner. Parameterising one clip
            // (rather than branching with `if`) keeps the subtree — and its live
            // FileDragSourceView — mounted for the whole drag.
            .clipShape(CollapseClip(collapsed: isExiting))
    }

    private var card: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 8) {
                    FilePreview(
                        fileURL: fileURL,
                        kind: item.kind,
                        contentType: item.contentType,
                        size: 62
                    )
                    Text(item.displayName)
                        .font(.callout)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.center)
                        .frame(width: 104)
                }
                .frame(width: 108)
                .overlay {
                    FileDragSourceView(
                        items: exportItems,
                        onExportStarted: onExportStarted,
                        onExportEnded: onExportEnded,
                        onItemExportFinished: onItemExportFinished,
                        onOpen: onOpen
                    )
                    .accessibilityLabel("Drag \(item.displayName)")
                }

                removeButton
            }

            sizeLabel
        }
        .foregroundStyle(.white)
        .contextMenu {
            Button(item.kind == .image ? "Quick Look" : "Open", action: onOpen)
            Button("Show in Finder", action: onReveal)
            Button("Remove from Shelf", role: .destructive, action: onRemove)
        }
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 22))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.62))
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .offset(x: 4, y: -4)
        .accessibilityLabel("Remove \(item.displayName)")
    }

    @ViewBuilder private var sizeLabel: some View {
        if let byteCount = item.byteCount {
            Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Text(item.kind == .folder ? "Folder" : "Item")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// A clip that tightens to the view's bounds only while `collapsed`, and
/// otherwise expands well past them so nothing is cut at rest. Being a single
/// parameterised `Shape` (not an `if`-branch), it never changes view identity —
/// so the tile's live `FileDragSourceView` survives the whole drag session.
private struct CollapseClip: Shape {
    var collapsed: Bool

    func path(in rect: CGRect) -> Path {
        Path(collapsed ? rect : rect.insetBy(dx: -200, dy: -200))
    }
}

private struct PendingTile: View {
    let transfer: PendingTransfer

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(0.06))
                ProgressView()
                    .controlSize(.small)
            }
            .frame(width: 62, height: 62)
            Text(transfer.displayName)
                .font(.footnote)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
                .frame(width: 104)
            Text(phaseLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .frame(width: 108)
        .accessibilityElement(children: .combine)
    }

    private var phaseLabel: String {
        switch transfer.phase {
        case .waitingForSource: "Receiving"
        case .downloadingFromCloud: "Downloading"
        case .copying: "Staging"
        }
    }
}
