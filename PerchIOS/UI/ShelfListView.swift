import PhotosUI
import SwiftUI

/// The phone's shelf: what's waiting, where it's going, and the ways to put
/// more on it. Deliberately not a file manager — a pocket that empties onto
/// the Mac.
struct ShelfListView: View {
    @ObservedObject var model: MobileAppModel

    @State private var showingPairSheet = false
    @State private var showingFileImporter = false
    @State private var showingPhotoPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Group {
                if model.items.isEmpty && model.remoteItems.isEmpty && receipts.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Perch")
            .toolbar { toolbar }
            .sheet(isPresented: $showingPairSheet) {
                PairMacView(model: model)
            }
            .sheet(item: $model.incoming) { file in
                ShareSheet(url: file.url)
            }
            // A PhotosPicker rendered inside a Menu never presents — the menu
            // dismisses and takes the picker's presentation with it. Driving it
            // from a flag set by an ordinary menu button is the fix.
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: $photoSelection,
                maxSelectionCount: nil,
                matching: .any(of: [.images, .videos])
            )
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.item, .folder],
                allowsMultipleSelection: true
            ) { result in
                if case let .success(urls) = result {
                    model.addFiles(urls)
                }
            }
            .onChange(of: photoSelection) { _, selection in
                importPhotos(selection)
            }
            .overlay(alignment: .bottom) {
                if let notice = model.notice {
                    NoticeBanner(text: notice) { model.notice = nil }
                }
            }
        }
    }

    private var receipts: [(id: UUID, date: Date)] {
        model.deliveries.compactMap { key, value in
            if case let .delivered(date) = value {
                return (id: key, date: date)
            }
            return nil
        }
        .sorted { $0.date > $1.date }
    }

    // MARK: - States

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing waiting", systemImage: "tray")
        } description: {
            Text(model.pairedMacName == nil
                ? "Share something to Perch, or pair your Mac to give this pocket somewhere to empty."
                : "Share something to Perch from any app and it'll be waiting on \(model.pairedMacName ?? "your Mac") — and whatever you drop on the shelf there shows up here.")
        } actions: {
            if model.pairedMacName == nil {
                Button("Pair a Mac") { showingPairSheet = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var list: some View {
        List {
            Section {
                presenceRow
            }
            if !model.items.isEmpty {
                Section("On this \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")") {
                    ForEach(model.items) { item in
                        ItemRow(
                            item: item,
                            state: model.deliveries[item.id, default: .waiting],
                            stagedURL: model.stagedURL(for: item)
                        )
                        .accessibilityAction(named: "Remove \(item.displayName)") {
                            model.remove(item)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                model.remove(item)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            if !model.remoteItems.isEmpty {
                Section {
                    ForEach(model.remoteItems) { entry in
                        let isFetching = model.fetching.contains(entry.id)
                        let location = model.pairedMacName ?? "your Mac"
                        let accessibilityValue = isFetching ? "Downloading" : "On \(location)"

                        Button {
                            Task { await model.fetch(entry) }
                        } label: {
                            RemoteRow(
                                entry: entry,
                                isFetching: isFetching
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(entry.displayName)
                        .accessibilityValue(accessibilityValue)
                        .accessibilityHint("Downloads this item to your device")
                        .accessibilityInputLabels([entry.displayName, "Download \(entry.displayName)"])
                        .accessibilityAction(named: "Remove \(entry.displayName)") {
                            Task { await model.removeRemote(entry) }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await model.removeRemote(entry) }
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("On \(model.pairedMacName ?? "your Mac")")
                        Spacer()
                        if model.isSyncing {
                            MotionAwareProgressView(
                                accessibilityLabel: "Syncing items",
                                isCompact: true
                            )
                        }
                    }
                } footer: {
                    Text("Tap to bring one here. Swipe to take it off the shelf.")
                }
            }
            if !receipts.isEmpty {
                Section("Delivered") {
                    ForEach(receipts, id: \.id) { receipt in
                        Label {
                            Text("Delivered \(receipt.date.formatted(.relative(presentation: .named)))")
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .refreshable {
            model.refresh()
            await model.flush()
            await model.syncRemote(announceFailure: true)
        }
    }

    @ViewBuilder
    private var presenceRow: some View {
        switch model.presence {
        case .none:
            Button {
                showingPairSheet = true
            } label: {
                Label("Pair a Mac", systemImage: "laptopcomputer.and.iphone")
            }
        case let .away(name):
            Label {
                VStack(alignment: .leading) {
                    Text(name)
                    Text("Away — items wait here until it's back")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "laptopcomputer.slash")
                    .foregroundStyle(.secondary)
            }
        case let .nearby(name):
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        nearbyLabel(name)
                        sendControl
                    }
                } else {
                    HStack {
                        nearbyLabel(name)
                        Spacer()
                        sendControl
                    }
                }
            }
        }
    }

    private func nearbyLabel(_ name: String) -> some View {
        Label {
            VStack(alignment: .leading) {
                Text(name)
                Text("Nearby")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "laptopcomputer")
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var sendControl: some View {
        if model.isFlushing {
            MotionAwareProgressView(accessibilityLabel: "Sending items")
        } else if !model.items.isEmpty {
            Button("Send") {
                Task { await model.flush() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    showingPhotoPicker = true
                } label: {
                    Label("From Photos", systemImage: "photo.on.rectangle")
                }
                Button {
                    showingFileImporter = true
                } label: {
                    Label("From Files", systemImage: "folder")
                }
                Button {
                    model.addPasteboard()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                if let name = model.pairedMacName {
                    Button(role: .destructive) {
                        model.unpair()
                    } label: {
                        Label("Unpair \(name)", systemImage: "xmark.circle")
                    }
                } else {
                    Button {
                        showingPairSheet = true
                    } label: {
                        Label("Pair a Mac", systemImage: "qrcode.viewfinder")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private func importPhotos(_ selection: [PhotosPickerItem]) {
        guard !selection.isEmpty else { return }
        photoSelection = []
        Task {
            for pick in selection {
                // Transferable hands us data; the filename is lost, so mint a
                // sensible one from the type.
                if let data = try? await pick.loadTransferable(type: Data.self) {
                    let type = pick.supportedContentTypes.first
                    let ext = type?.preferredFilenameExtension ?? "jpg"
                    let base = type?.conforms(to: .movie) == true ? "Video" : "Photo"
                    model.addData(data, displayName: "\(base).\(ext)")
                }
            }
        }
    }
}

/// One staged thing and where it stands.
private struct ItemRow: View {
    let item: ShelfItem
    let state: MobileShelf.Delivery
    let stagedURL: URL?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 36

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: min(iconSize, 72), height: min(iconSize, 72))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let stagedURL {
                ShareLink(item: stagedURL) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Share \(item.displayName)")
                .accessibilityInputLabels(["Share \(item.displayName)", "Share"])
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let bytes = item.byteCount {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        if case .waiting = state {
            parts.append("waiting")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var icon: some View {
        if item.kind == .image, let stagedURL,
           let image = UIImage(contentsOfFile: stagedURL.path) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: min(iconSize, 72), height: min(iconSize, 72))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var symbolName: String {
        switch item.kind {
        case .file: "doc"
        case .folder: "folder"
        case .image: "photo"
        case .link: "link"
        case .text: "text.alignleft"
        }
    }
}

/// One thing sitting on the Mac's shelf. Tapping pulls it down; the row shows
/// that pull happening, because on a phone a tap that does nothing visible for
/// two seconds reads as a tap that missed.
private struct RemoteRow: View {
    let entry: RemoteEntry
    let isFetching: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 36

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: min(iconSize, 72), height: min(iconSize, 72))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isFetching {
                MotionAwareProgressView(accessibilityLabel: "Downloading")
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let bytes = entry.byteCount {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        parts.append(entry.addedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    private var symbolName: String {
        switch ShelfItem.Kind(rawValue: entry.kindHint) {
        case .folder: "folder"
        case .image: "photo"
        case .link: "link"
        case .text: "text.alignleft"
        case .file, nil: "doc"
        }
    }
}

/// The system share sheet, which is what "save this on my phone" actually
/// means on iOS — Files, Photos, or straight into another app.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            Text(text)
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Dismisses this notification")
        .padding(.bottom, 12)
        .onAppear {
            UIAccessibility.post(notification: .announcement, argument: text)
        }
        .task {
            try? await Task.sleep(for: .seconds(4))
            dismiss()
        }
    }
}
