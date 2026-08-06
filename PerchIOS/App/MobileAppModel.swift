import Foundation
import Network
import SwiftUI
import UIKit

/// Everything the iOS app's UI observes: the local shelf, the paired Mac and
/// whether it is on the network right now, and the state of an in-flight
/// pairing.
@MainActor
final class MobileAppModel: ObservableObject {
    enum MacPresence: Equatable {
        case none
        case away(name: String)
        case nearby(name: String)
    }

    enum PairingPhase: Equatable {
        case idle
        case searching
        /// The phone has done its part; the code is shown passively while the
        /// person presses Approve on the Mac. No tap needed here — possession
        /// of the QR secret already authenticated both ends, the digits are
        /// only there to compare if you're worried someone photographed your
        /// QR.
        case awaitingMacApproval(code: String)
        case failed(String)
    }

    /// A file just pulled off the Mac, on its way to the share sheet.
    struct IncomingFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var deliveries: [UUID: MobileShelf.Delivery] = [:]
    @Published private(set) var presence: MacPresence = .none
    @Published private(set) var pairingPhase: PairingPhase = .idle
    @Published private(set) var isFlushing = false
    /// What the Mac's shelf holds, as of the last sync.
    @Published private(set) var remoteItems: [RemoteEntry] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var fetching: Set<UUID> = []
    @Published var incoming: IncomingFile?
    @Published var notice: String?

    let shelf: MobileShelf?
    private let pairing = MacPairingStore()
    private let browser = WireBrowser()
    private var discovered: [DiscoveredMac] = []
    /// Bumped when the user cancels, so a lingering pairing task can't write
    /// state (or worse, store a pairing) after being abandoned.
    private var pairingAttempt = 0
    /// The foreground poll. The Mac never dials a phone, so "shared and in
    /// sync" has to mean the phone asks — often enough to feel live, rarely
    /// enough to stay invisible.
    private var syncTask: Task<Void, Never>?
    private static let syncInterval = Duration.seconds(5)

    init() {
        shelf = try? MobileShelf()
        if shelf == nil {
            notice = "Perch could not open its storage. Reinstalling the app may help."
        }
        refresh()
    }

    // MARK: - Lifecycle

    func becameActive() {
        refresh()
        shelf?.pruneReceipts()
        MobileRemote.pruneInbox()
        startBrowsing()
        startSyncing()
        // Automated end-to-end runs stage and pair from the environment —
        // there is no finger to do it.
        #if DEBUG
        if let text = ProcessInfo.processInfo.environment["PERCH_AUTOSEND_TEXT"],
           let shelf, items.isEmpty {
            _ = try? shelf.stageText(text)
            refresh()
        }
        if let offerString = ProcessInfo.processInfo.environment["PERCH_PAIR_OFFER"],
           pairedMacName == nil {
            pair(with: offerString)
        }
        #endif
    }

    func becameInactive() {
        browser.stop()
        syncTask?.cancel()
        syncTask = nil
    }

    func refresh() {
        guard let shelf else { return }
        items = shelf.items()
        deliveries = shelf.deliveries()
        let paired = pairing.pairedMac()
        switch (paired, discovered.first(where: { $0.macID == paired?.id })) {
        case (nil, _):
            presence = .none
        case let (mac?, nil):
            presence = .away(name: mac.name)
        case let (mac?, _?):
            presence = .nearby(name: mac.name)
        }
        // An away Mac's shelf is unknowable, not empty-but-stale: showing the
        // last list would invite taps that can only fail.
        if case .nearby = presence {} else {
            remoteItems = []
        }
    }

    /// The paired Mac's endpoint if the live browser can see it right now.
    private var macEndpoint: NWEndpoint? {
        guard let mac = pairing.pairedMac() else { return nil }
        return discovered.first(where: { $0.macID == mac.id })?.endpoint
    }

    private func startBrowsing() {
        browser.start { [weak self] macs in
            Task { @MainActor [weak self] in
                guard let self else { return }
                discovered = macs
                let wasAway = if case .away = presence { true } else { false }
                refresh()
                // The Mac just walked in and things are waiting — deliver, and
                // find out what it has been holding while we were apart.
                if wasAway, case .nearby = presence {
                    await flush()
                    await syncRemote()
                }
            }
        }
    }

    private func startSyncing() {
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncRemote()
                try? await Task.sleep(for: MobileAppModel.syncInterval)
            }
        }
    }

    // MARK: - Adding

    func addFiles(_ urls: [URL]) {
        guard let shelf else { return }
        // Copies happen off the main actor; a dropped 2 GB video must not
        // freeze the list.
        Task.detached { [shelf] in
            var firstError: String?
            for url in urls {
                do {
                    _ = try shelf.stageFile(at: url)
                } catch {
                    firstError = firstError ?? error.localizedDescription
                }
            }
            await MainActor.run { [firstError] in
                if let firstError {
                    self.notice = firstError
                }
                self.refresh()
            }
            await self.flush()
        }
    }

    func addData(_ data: Data, displayName: String) {
        guard let shelf else { return }
        Task.detached { [shelf] in
            let failure: String?
            do {
                _ = try shelf.stageData(data, displayName: displayName)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { [failure] in
                if let failure {
                    self.notice = failure
                }
                self.refresh()
            }
            await self.flush()
        }
    }

    func addPasteboard() {
        guard let shelf else { return }
        let board = UIPasteboard.general
        do {
            if let url = board.url {
                _ = try shelf.stageLink(url, title: nil)
            } else if let text = board.string, !text.isEmpty {
                _ = try shelf.stageText(text)
            } else if let image = board.image, let png = image.pngData() {
                _ = try shelf.stageData(png, displayName: "Image.png")
            } else {
                notice = "Nothing usable on the clipboard."
                return
            }
        } catch {
            notice = error.localizedDescription
        }
        refresh()
        Task { await flush() }
    }

    func remove(_ item: ShelfItem) {
        guard let shelf else { return }
        try? shelf.remove(item)
        refresh()
    }

    func stagedURL(for item: ShelfItem) -> URL? {
        guard let shelf else { return nil }
        return item.fileURL(inside: shelf.repository.rootURL)
    }

    // MARK: - Delivering

    func flush() async {
        guard let shelf, !isFlushing else { return }
        isFlushing = true
        defer {
            isFlushing = false
            refresh()
        }
        switch await MobileDelivery.flush(shelf: shelf, pairing: pairing) {
        case let .delivered(count):
            notice = count == 1 ? "1 item is on your Mac." : "\(count) items are on your Mac."
            // What just left the phone is now the Mac's; show it there rather
            // than making the user wait for the next poll to believe it.
            await syncRemote()
        case let .waiting(count, reason):
            if let reason {
                notice = reason
            } else {
                notice = count == 1
                    ? "1 item is waiting for your Mac."
                    : "\(count) items are waiting for your Mac."
            }
        case .nothingWaiting, .notPaired:
            break
        }
    }

    // MARK: - The Mac's half of the shelf

    /// Asks the Mac what it is holding. Cheap and silent by design: it runs on
    /// a timer, so an away Mac or an in-flight sync must cost nothing and say
    /// nothing.
    func syncRemote(announceFailure: Bool = false) async {
        guard pairing.pairedMac() != nil else {
            remoteItems = []
            return
        }
        guard !isSyncing else { return }
        guard let endpoint = macEndpoint else {
            remoteItems = []
            if announceFailure, case let .away(name) = presence {
                notice = "\(name) isn't on this network right now."
            }
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        do {
            remoteItems = try await MobileRemote.list(pairing: pairing, endpoint: endpoint)
        } catch {
            if announceFailure {
                notice = error.localizedDescription
            }
        }
    }

    /// Pulls one item down and hands it to the share sheet — the phone's only
    /// honest "save": iOS has no shelf of its own to drop it on.
    func fetch(_ entry: RemoteEntry) async {
        guard !fetching.contains(entry.id) else { return }
        guard entry.kindHint != ShelfItem.Kind.folder.rawValue else {
            notice = "Folders can't be pulled to a phone yet."
            return
        }
        fetching.insert(entry.id)
        defer { fetching.remove(entry.id) }
        do {
            let url = try await MobileRemote.fetch(
                entry,
                pairing: pairing,
                endpoint: macEndpoint
            )
            incoming = IncomingFile(url: url)
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Swiping an item away on the phone takes it off the Mac's shelf too —
    /// one shelf, two windows onto it.
    func removeRemote(_ entry: RemoteEntry) async {
        let previous = remoteItems
        remoteItems.removeAll { $0.id == entry.id }
        do {
            try await MobileRemote.remove(entry, pairing: pairing, endpoint: macEndpoint)
        } catch {
            notice = error.localizedDescription
            remoteItems = previous
        }
    }

    // MARK: - Pairing

    var pairedMacName: String? {
        pairing.pairedMac()?.name
    }

    func pair(with offerString: String) {
        guard let offer = PairingOffer.decode(from: offerString) else {
            pairingPhase = .failed("That does not look like a Perch pairing code.")
            return
        }
        pairingPhase = .searching
        pairingAttempt += 1
        let attempt = pairingAttempt
        Task {
            await runPairing(offer, attempt: attempt)
        }
    }

    func resetPairing() {
        pairingAttempt += 1
        pairingPhase = .idle
    }

    func unpair() {
        pairing.unpair()
        refresh()
    }

    private func runPairing(_ offer: PairingOffer, attempt: Int) async {
        guard let endpoint = await MobileDelivery.discover(
            macID: offer.macID,
            timeout: .seconds(10)
        ) else {
            if attempt == pairingAttempt {
                pairingPhase = .failed("“\(offer.macName)” is not visible on this network. Same Wi-Fi, Perch running?")
            }
            return
        }
        let identity = MobileConfig.deviceIdentity()
        do {
            let mac = try await WirePairingClient.pair(
                offer: offer,
                endpoint: endpoint,
                deviceID: identity.id,
                deviceName: identity.name
            ) { [weak self] code in
                // The phone's half is done the moment the keys agree; show
                // the digits and hand the one human decision to the Mac.
                await MainActor.run { [weak self] in
                    guard let self, attempt == self.pairingAttempt else { return }
                    self.pairingPhase = .awaitingMacApproval(code: code)
                }
                return true
            }
            guard attempt == pairingAttempt else { return }
            try pairing.store(mac)
            pairingPhase = .idle
            notice = "Paired with \(mac.name)."
            refresh()
            await flush()
        } catch {
            if attempt == pairingAttempt {
                pairingPhase = .failed(error.localizedDescription)
            }
        }
    }
}
