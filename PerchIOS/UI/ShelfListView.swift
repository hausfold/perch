import PhotosUI
import SwiftUI

/// The phone's shelf: what's waiting, where it's going, and the ways to put
/// more on it. Deliberately not a file manager — a pocket that empties onto
/// the Mac.
struct ShelfListView: View {
    @ObservedObject var model: MobileAppModel

    @State private var showingPairSheet = false
    @State private var showingFileImporter = false
    @State private var photoSelection: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            Group {
                if model.items.isEmpty && receipts.isEmpty {
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
                : "Share something to Perch from any app and it'll be waiting on \(model.pairedMacName ?? "your Mac").")
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
            HStack {
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
                Spacer()
                if model.isFlushing {
                    ProgressView()
                } else if !model.items.isEmpty {
                    Button("Send") {
                        Task { await model.flush() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                PhotosPicker(
                    selection: $photoSelection,
                    matching: .any(of: [.images, .videos])
                ) {
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

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)
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
                .frame(width: 36, height: 36)
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

private struct NoticeBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 12)
            .onTapGesture(perform: dismiss)
            .task {
                try? await Task.sleep(for: .seconds(4))
                dismiss()
            }
    }
}
