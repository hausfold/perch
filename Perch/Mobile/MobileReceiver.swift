import AppKit
import Foundation
import OSLog

/// The Mac's mobile door: owns the wire server, the pairing window's state,
/// and the bridge between arriving bytes and the shelf.
///
/// Threading shape: the wire server calls the delegate methods from its own
/// tasks; everything that touches `ShelfStore` hops to the main actor, and
/// everything published for SwiftUI lives in the `@MainActor` surface below.
@MainActor
final class MobileReceiver: ObservableObject {
    /// A pairing window that is currently open on screen.
    struct PairingWindow {
        let offer: PairingOffer
        let encodedOffer: String
    }

    /// A phone mid-pairing, waiting for the person at the Mac to answer.
    struct PairingApproval: Identifiable {
        let id = UUID()
        let deviceName: String
        let code: String
        let answer: (Bool) -> Void
    }

    @Published private(set) var pairingWindow: PairingWindow?
    @Published private(set) var pendingApproval: PairingApproval?
    @Published private(set) var pairedDevices: [PairedPeer] = []
    @Published private(set) var isListening = false
    @Published var lastEvent: String?

    private let store: ShelfStore
    private let settings: AppSettings
    private let devices = PairedDeviceStore()
    private let identity = MacWireIdentity.current()
    private var server: WireServer?
    private let logger = Logger(subsystem: "com.nebelhaus.perch", category: "MobileReceiver")
    /// Captured once so the wire server can ask for the spool root without a
    /// main-actor hop mid-stream.
    private nonisolated let shelfRoot: URL

    init(store: ShelfStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        shelfRoot = store.repository.rootURL
        pairedDevices = devices.all()
    }

    // MARK: - Lifecycle

    func start() {
        guard settings.mobileEnabled, server == nil else { return }
        let server = WireServer(delegate: Bridge(receiver: self))
        do {
            try server.start(identity: identity)
            self.server = server
            isListening = true
        } catch {
            lastEvent = error.localizedDescription
            logger.error("Mobile listener failed to start: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Automated end-to-end runs have no one to click "Pair a Device…":
        // open a pairing window headlessly and drop its offer where the test
        // harness said to look.
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["PERCH_PAIR_OFFER_PATH"],
           pairingWindow == nil {
            openPairingWindow()
            if let encoded = pairingWindow?.encodedOffer {
                try? encoded.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        #endif
    }

    func stop() {
        server?.stop()
        server = nil
        isListening = false
        closePairingWindow()
    }

    func applyEnabledSetting() {
        settings.mobileEnabled ? start() : stop()
    }

    // MARK: - Pairing window

    func openPairingWindow() {
        // Asking to pair IS asking for the feature: with the toggle off the
        // listener would silently never start, leaving a QR that can't work.
        settings.mobileEnabled = true
        // A fresh secret per window; the old one dies with the old window.
        let offer = PairingOffer(
            macID: identity.id,
            macName: identity.name,
            secret: WireCrypto.randomSecret()
        )
        guard let encoded = try? offer.encodedString() else { return }
        pairingWindow = PairingWindow(offer: offer, encodedOffer: encoded)
        start()
    }

    func closePairingWindow() {
        pairingWindow = nil
        if let approval = pendingApproval {
            approval.answer(false)
            pendingApproval = nil
        }
    }

    func revoke(_ peer: PairedPeer) {
        devices.revoke(peer.id)
        pairedDevices = devices.all()
    }

    // MARK: - Wire delegate bridge
    //
    // A tiny Sendable shim so the wire server never holds the MainActor
    // receiver directly; every call hops in with the right isolation.

    private struct Bridge: WireServerDelegate {
        let receiver: MobileReceiver

        func identity() async -> MacIdentity {
            await receiver.identity
        }

        func activePairingSecret() async -> Data? {
            await receiver.pairingWindow?.offer.secret
        }

        func approvePairing(deviceID: UUID, deviceName: String, code: String) async -> Bool {
            await receiver.requestApproval(deviceName: deviceName, code: code)
        }

        func storePairedPeer(_ peer: PairedPeer) async throws {
            try await receiver.finishPairing(peer)
        }

        func pairedPeer(for deviceID: UUID) async -> PairedPeer? {
            await receiver.lookup(deviceID)
        }

        func admit(_ items: [OfferedItem], from peer: PairedPeer) async -> (accepted: [OfferedItem], refused: [RefusedItem]) {
            await receiver.admitOffer(items, from: peer)
        }

        func spoolDirectory() async throws -> URL {
            try await receiver.spoolDirectory()
        }

        func commit(_ item: OfferedItem, stagedFileURL: URL, from peer: PairedPeer) async throws {
            try await receiver.commitArrival(item, spooledAt: stagedFileURL, from: peer)
        }

        func transferFailed(_ item: OfferedItem, from peer: PairedPeer, reason: String) async {
            await receiver.arrivalFailed(item, reason: reason)
        }
    }

    // MARK: - Pairing plumbing

    private func requestApproval(deviceName: String, code: String) async -> Bool {
        // Automated end-to-end runs can't click an approval sheet.
        #if DEBUG
        if ProcessInfo.processInfo.environment["PERCH_AUTOPAIR"] == "1" {
            return true
        }
        #endif
        guard pairingWindow != nil else { return false }
        return await withCheckedContinuation { continuation in
            // A second phone mid-pairing replaces the first ask; the first
            // resolves to "no" rather than dangling forever.
            if let existing = pendingApproval {
                existing.answer(false)
            }
            let resumed = ResumeGuard()
            pendingApproval = PairingApproval(
                deviceName: deviceName,
                code: code
            ) { approved in
                if resumed.claim() {
                    continuation.resume(returning: approved)
                }
            }
        }
    }

    func answerApproval(_ approval: PairingApproval, approved: Bool) {
        approval.answer(approved)
        pendingApproval = nil
    }

    private func finishPairing(_ peer: PairedPeer) throws {
        try devices.store(peer)
        pairedDevices = devices.all()
        lastEvent = "Paired \(peer.name)."
        // The window did its job; the secret must not pair a second device.
        pairingWindow = nil
    }

    private func lookup(_ deviceID: UUID) -> PairedPeer? {
        devices.peer(for: deviceID)
    }

    // MARK: - Arrivals

    private func admitOffer(_ items: [OfferedItem], from peer: PairedPeer) -> (accepted: [OfferedItem], refused: [RefusedItem]) {
        let decision = store.admitMobileItems(items, deviceName: peer.name)
        if !decision.accepted.isEmpty {
            lastEvent = "Receiving \(decision.accepted.count) item\(decision.accepted.count == 1 ? "" : "s") from \(peer.name)…"
        }
        return decision
    }

    private nonisolated func spoolDirectory() throws -> URL {
        let root = ShelfStore.mobileSpoolRoot(inside: shelfRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func commitArrival(_ item: OfferedItem, spooledAt url: URL, from peer: PairedPeer) throws {
        try store.completeMobileImport(item, spooledAt: url)
        lastEvent = "\(item.displayName) arrived from \(peer.name)."
    }

    private func arrivalFailed(_ item: OfferedItem, reason: String) {
        store.failMobileImport(item.id)
        lastEvent = "\(item.displayName) failed: \(reason)"
    }
}
