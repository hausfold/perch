import Social
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// NSItemProvider is documented thread-safe ("can be used from any thread");
/// the conformance lets staging run off the main actor without ceremony.
extension NSItemProvider: @unchecked @retroactive Sendable {}

/// The Share-sheet face of Perch: stage local copies of whatever the host app
/// offered, then try — briefly — to hand them to the Mac. Staging is the
/// promise ("it's on Perch"); delivery is opportunistic and honest about
/// which of the two happened.
final class ShareViewController: UIViewController {
    private let state = ShareState()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareStatusView(
            state: state,
            done: { [weak self] in self?.finish() }
        ))
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)

        let providers = (extensionContext?.inputItems ?? [])
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
        Task { await run(providers) }
    }

    private func run(_ providers: [NSItemProvider]) async {
        guard let shelf = try? MobileShelf() else {
            state.phase = .failed("Perch could not open its storage.")
            return
        }
        let pairing = MacPairingStore()

        var staged = 0
        var stagedLinks: Set<String> = []
        for provider in Self.distinct(providers) {
            do {
                let item = try await Self.stage(provider, onto: shelf)
                // Two providers can still resolve to the same page (a share
                // that offers the URL twice under different types). A link
                // already staged in this same share is that page again, not a
                // second one.
                if item.kind == .link, !stagedLinks.insert(item.displayName).inserted {
                    try? shelf.remove(item)
                    continue
                }
                staged += 1
                state.stagedCount = staged
            } catch {
                // One unreadable attachment shouldn't sink the rest.
                continue
            }
        }
        guard staged > 0 else {
            state.phase = .failed("Nothing in this share could be read.")
            return
        }

        guard pairing.pairedMac() != nil else {
            state.phase = .keptLocally("On Perch. Pair a Mac in the app to send things onward.")
            scheduleFinish()
            return
        }

        state.phase = .sending
        switch await MobileDelivery.flush(shelf: shelf, pairing: pairing) {
        case .delivered:
            state.phase = .delivered(pairing.pairedMac()?.name ?? "your Mac")
            scheduleFinish()
        case .waiting:
            state.phase = .keptLocally("Waiting for \(pairing.pairedMac()?.name ?? "your Mac"). It'll go over when you're both home.")
            scheduleFinish()
        case .nothingWaiting, .notPaired:
            state.phase = .keptLocally("On Perch.")
            scheduleFinish()
        }
    }

    /// One share is one thing, however many ways the host describes it.
    ///
    /// Safari (and anything else sharing a web page) attaches *several*
    /// representations: the page URL as `public.url`, and its title — or the
    /// URL again — as `public.plain-text`. Staging every attachment landed the
    /// page on the Mac twice. When the share carries a link, loose text
    /// alongside it is that link's title, not a second thing worth shelving.
    /// Files and images are never dropped: those genuinely are separate items.
    nonisolated static func distinct(_ providers: [NSItemProvider]) -> [NSItemProvider] {
        let carriesLink = providers.contains {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                && !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard carriesLink else { return providers }
        return providers.filter { !isTextOnly($0) }
    }

    /// A provider that offers nothing but text — no file, no URL, no image.
    private nonisolated static func isTextOnly(_ provider: NSItemProvider) -> Bool {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        guard !types.isEmpty else { return false }
        return types.allSatisfy { $0.conforms(to: .text) }
    }

    /// Stage one attachment, favouring the richest representation the host
    /// offers: a real file first, then a link, then bare text or image data.
    /// `nonisolated`: a UIViewController's statics inherit @MainActor, and
    /// this one copies files.
    nonisolated static func stage(_ provider: NSItemProvider, onto shelf: MobileShelf) async throws -> ShelfItem {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let item = try await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
            if let url = item as? URL {
                return try shelf.stageFile(at: url)
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let item = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
            if let url = item as? URL {
                return try shelf.stageLink(url, title: provider.suggestedName)
            }
        }
        // Anything file-like (images from Photos, PDFs from Mail, movies…)
        // arrives through a file representation the system stages for us just
        // long enough to copy.
        if let typeID = provider.registeredTypeIdentifiers.first(where: { id in
            UTType(id)?.conforms(to: .data) ?? false
        }) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, error in
                    guard let url else {
                        continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile))
                        return
                    }
                    // The URL dies with this closure — the copy must happen here.
                    let name = provider.suggestedName.map {
                        $0.contains(".") ? $0 : "\($0).\(url.pathExtension)"
                    }
                    continuation.resume(with: Result {
                        try shelf.stageFile(at: url, displayName: name)
                    })
                }
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let item = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
            if let text = item as? String {
                return try shelf.stageText(text)
            }
        }
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    private func scheduleFinish() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            finish()
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

/// The few states worth showing in the couple of seconds the sheet lives.
@MainActor
final class ShareState: ObservableObject {
    enum Phase: Equatable {
        case staging
        case sending
        case delivered(String)
        case keptLocally(String)
        case failed(String)
    }

    @Published var phase: Phase = .staging
    @Published var stagedCount = 0
}

struct ShareStatusView: View {
    @ObservedObject var state: ShareState
    let done: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            switch state.phase {
            case .staging:
                ProgressView()
                Text("Putting on Perch…")
                    .foregroundStyle(.secondary)
            case .sending:
                ProgressView()
                Text("Sending to your Mac…")
                    .foregroundStyle(.secondary)
            case let .delivered(macName):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                Text("On \(macName)")
                    .font(.headline)
            case let .keptLocally(message):
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                Button("Done", action: done)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
