import AppKit
import SwiftUI

struct ShelfPanelView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: ShelfPanelState

    let onExpand: () -> Void
    let onCollapse: () -> Void

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
        .accessibilityLabel("Morsel file shelf")
    }

    private var collapsedShelf: some View {
        ZStack(alignment: .bottom) {
            Color.black
            HStack(spacing: 6) {
                Image(systemName: state.hasCameraHousing ? "chevron.down" : "tray")
                if !store.items.isEmpty || !store.pendingTransfers.isEmpty {
                    Text("\(store.items.count + store.pendingTransfers.count)")
                        .font(.caption2.weight(.semibold))
                        .contentTransition(.numericText())
                } else if !state.hasCameraHousing {
                    Text("Drop here")
                        .font(.caption2.weight(.medium))
                }
            }
            .foregroundStyle(.white.opacity(0.72))
            .padding(.bottom, 5)
        }
        .clipShape(
            .rect(
                bottomLeadingRadius: 14,
                bottomTrailingRadius: 14
            )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
    }

    private var expandedShelf: some View {
        ZStack {
            GlassBackground(cornerRadius: 28)
            Color.black.opacity(0.74)

            VStack(spacing: 12) {
                header

                if store.items.isEmpty && store.pendingTransfers.isEmpty {
                    emptyState
                } else {
                    itemStrip
                }

                footer
            }
            .padding(.horizontal, 16)
            .padding(.top, state.hasCameraHousing ? 40 : 14)
            .padding(.bottom, 13)
        }
        .clipShape(
            .rect(
                bottomLeadingRadius: 28,
                bottomTrailingRadius: 28
            )
        )
        .overlay(alignment: .bottom) {
            if let error = store.latestError {
                errorBanner(error)
                    .padding(10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full.fill")
                .foregroundStyle(Color.accentColor)
            Text("Morsel")
                .font(.headline)
            Text(itemCountDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !store.items.isEmpty {
                Button("Clear", role: .destructive) {
                    store.clear()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .accessibilityHint("Deletes every staged copy")
            }
            Button(action: onCollapse) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse shelf")
        }
        .foregroundStyle(.white)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 31, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Drop files into the notch")
                .font(.callout.weight(.semibold))
            Text("Finder files, Photos, Safari images, links, and text")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
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

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.doc")
            Text(store.items.count > 1 ? "Drag any item to copy all \(store.items.count)" : "Drag out to copy")
            Spacer()
            Text("Originals stay untouched")
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.55))
        .lineLimit(1)
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
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: 94)
                }
                .padding(10)
                .frame(width: 114, height: 124)
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(item.kind == .folder ? "Folder" : "Item")
                    .font(.caption2)
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
