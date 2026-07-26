import AppKit
import SwiftUI

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
        // A device with a real notch never renders the synthetic notch — the
        // physical housing is the affordance. On notchless displays the pill
        // only appears once there is something staged to grab back out.
        //
        // The whole collapsed frame is made hit-testable with contentShape even
        // when it draws nothing: without it, SwiftUI's Color.clear reports no
        // hit, NSHostingView.hitTest returns nil, and AppKit never routes an
        // incoming drag here — so draggingEntered would never fire.
        Group {
            if !state.hasCameraHousing && hasContent {
                notchlessPill
            } else {
                // A non-opaque window derives its draggable/clickable region
                // from rendered alpha: fully transparent pixels are treated as
                // click-through and never receive draggingEntered. So while a
                // drag might be underway (armed) the catch zone is filled at the
                // lowest alpha that still registers as a drop target; when idle
                // it is fully transparent — nothing to see, nothing to catch.
                Color.black.opacity(state.isArmed ? catchZoneAlpha : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
    }

    /// Lowest fill alpha that keeps the collapsed window a valid drop target.
    private let catchZoneAlpha = 0.005

    private var notchlessPill: some View {
        ZStack(alignment: .bottom) {
            Color.black
            HStack(spacing: 5) {
                Image(systemName: "tray.full.fill")
                    .font(.caption2)
                Text("\(store.items.count + store.pendingTransfers.count)")
                    .font(.caption2.weight(.semibold))
                    .contentTransition(.numericText())
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.bottom, 5)
        }
        .clipShape(.rect(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
    }

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
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 8)
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
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(store.items) { item in
                    FileTile(
                        item: item,
                        fileURL: item.fileURL(inside: store.repository.rootURL),
                        allExportURLs: store.exportedURLs,
                        onReveal: { store.reveal(item) },
                        onRemove: { store.remove(item) },
                        onExportStarted: { state.isDropActive = true },
                        onExportEnded: { state.isDropActive = false },
                        onSuccessfulExport: { store.completeExport() }
                    )
                }
                ForEach(store.pendingTransfers) { transfer in
                    PendingTile(transfer: transfer)
                }
            }
            .padding(.vertical, 3)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity)
    }

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
                    .font(.footnote.weight(.semibold))
                Text(title)
                    .font(.callout.weight(.medium))
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
    let allExportURLs: [URL]
    let onReveal: () -> Void
    let onRemove: () -> Void
    let onExportStarted: () -> Void
    let onExportEnded: () -> Void
    let onSuccessfulExport: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 7) {
                    icon
                    Text(item.displayName)
                        .font(.subheadline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: 100)
                }
                .padding(11)
                .frame(width: 122, height: 132)
                .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    FileDragSourceView(
                        urls: allExportURLs,
                        onExportStarted: onExportStarted,
                        onExportEnded: onExportEnded,
                        onSuccessfulExport: onSuccessfulExport
                    )
                    .accessibilityLabel("Drag \(item.displayName) and all shelf items")
                }

                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.65))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .accessibilityLabel("Remove \(item.displayName)")
            }

            if let byteCount = item.byteCount {
                Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(item.kind == .folder ? "Folder" : "Item")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .contextMenu {
            Button("Show in Finder", action: onReveal)
            Button("Remove from Shelf", role: .destructive, action: onRemove)
        }
    }

    private var icon: some View {
        Group {
            if let fileURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "doc")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }
}

private struct PendingTile: View {
    let transfer: PendingTransfer

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(transfer.displayName)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(phaseLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(width: 114, height: 148)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
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
