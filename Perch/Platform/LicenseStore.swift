import Foundation
import os

// MARK: - LicenseStore
//
// Owns the app's licensing state and the one rule the free tier enforces: an
// unlicensed shelf holds two tiles.
//
// **Why a cap and not a trial timer.** Perch's value is habitual — the third
// week is when you stop reaching for a Downloads window. A timer converts on a
// deadline; a cap converts on the moment someone actually feels the ceiling,
// and lets light use stay free forever. It is also the only shape that is
// honest under the sandbox: trial state lives in a container the user can
// delete in one Finder move, so a timer would be theatre.
//
// **What the cap never does.** It never blocks a drag mid-flight and it never
// loses a drop. Admission is decided *before* staging starts — the excess items
// are simply not taken, the originals are untouched (perch only ever copies),
// and the shelf says so in the strip. Nothing is staged and then thrown away.

@MainActor
final class LicenseStore: ObservableObject {
    static let shared = LicenseStore()

    /// The current entitlement. Everything downstream reads this.
    @Published private(set) var state: LicenseState = .free
    /// Transient line for the shelf strip after a drop hit the cap, cleared on
    /// a timer or the strip's ✕. Nil most of the time.
    @Published private(set) var capNote: String?
    /// The result of the last import attempt, for the Settings pane.
    @Published private(set) var importNote: String?

    /// How many tiles an unlicensed shelf holds.
    ///
    /// A product knob, not a code knob: watch conversion before moving it, and
    /// only ever move it *looser*. Tightening a free tier reads as a rug-pull.
    nonisolated static let freeTierCapacity = 2

    /// Where the store buys a license. Same page the README points at.
    ///
    /// hausfold is the seller — the name on the receipt, the terms and the
    /// refund policy — so the page lives on hausfold.co, not on nebelhaus.com.
    /// `/perch` there is a real page as of 2026-08-08; `nebelhaus.com/perch`
    /// still resolves and will 301 here when the site consolidates.
    nonisolated static let purchaseURL = URL(string: "https://hausfold.co/perch")!

    private let defaults: UserDefaults
    private let verifier: LicenseVerifier
    private let logger = Logger(subsystem: "com.nebelhaus.perch", category: "License")
    private var noteTask: Task<Void, Never>?

    private enum Key {
        /// The raw license file, verbatim, in the container's own defaults.
        static let blob = "license.blob"
        /// DEBUG-only escape hatch, so the cap can be feel-tested in Xcode.
        static let forceFree = "licenseDebugForceFree"
    }

    init(
        defaults: UserDefaults = .standard,
        verifier: LicenseVerifier = .production,
        buildVersion: String? = nil
    ) {
        self.defaults = defaults
        self.verifier = verifier
        reload(buildVersion: buildVersion ?? Self.liveBuildVersion)
    }

    // MARK: Entitlement

    /// The running build's CalVer, or a placeholder for an Xcode build.
    nonisolated static var liveBuildVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !version.isEmpty,
           version != "$(MARKETING_VERSION)" {
            return version
        }
        return "dev"
    }

    /// Re-derive `state` from what's stored. Called at init and after an import.
    func reload(buildVersion: String = LicenseStore.liveBuildVersion) {
        // A debug build is always licensed, exactly like the update check never
        // nudges one: developing perch shouldn't mean tripping over its own
        // paywall. The escape hatch exists so the cap and its strip can still be
        // exercised — `defaults write com.nebelhaus.perch licenseDebugForceFree -bool YES`.
        #if DEBUG
        if !defaults.bool(forKey: Key.forceFree) {
            state = .licensed(
                License(
                    product: License.expectedProduct,
                    email: "debug@nebelhaus.com",
                    purchased: "2026-01-01",
                    seats: 1,
                    sig: ""
                )
            )
            return
        }
        #endif

        guard let blob = defaults.data(forKey: Key.blob) else {
            state = .free
            return
        }
        guard let license = try? verifier.license(from: blob) else {
            // Stored bytes that no longer verify: keep them (a future build may
            // carry a rotated key) but run the free tier now.
            logger.error("license: stored file did not verify")
            state = .free
            return
        }
        state = license.covers(buildVersion: buildVersion) ? .licensed(license) : .uncovered(license)
    }

    // MARK: Import / removal

    /// Read a `.nebelhauslicense` from disk, verify it, and store it on success.
    ///
    /// Both entry points land here: the Settings picker and — the most perch way
    /// imaginable to activate perch — dropping the file on the shelf.
    @discardableResult
    func importLicense(from url: URL) -> Bool {
        // A file picked or dropped by the user is inside the sandbox's grant,
        // but a security-scoped URL still has to be opened explicitly.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            importNote = LicenseError.malformed.localizedDescription
            return false
        }
        return importLicense(data: data)
    }

    @discardableResult
    func importLicense(data: Data) -> Bool {
        do {
            let license = try verifier.license(from: data)
            defaults.set(data, forKey: Key.blob)
            reload()
            importNote = state.isLicensed
                ? "Licensed to \(license.email) — thank you."
                : "Licensed to \(license.email), but this build is outside the update year."
            return true
        } catch {
            importNote = error.localizedDescription
            logger.error("license: import rejected — \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Forget the stored license — for moving a seat, or testing the free tier.
    func removeLicense() {
        defaults.removeObject(forKey: Key.blob)
        reload()
        importNote = nil
    }

    /// Does this URL look like a license rather than something to stage?
    nonisolated static func isLicenseFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == License.fileExtension
    }

    // MARK: The cap

    /// Is this build able to honour a license at all?
    ///
    /// False until Phase 2 bakes the public key in — and while it is false the
    /// cap must not exist. A build that caps the shelf while no license it
    /// could accept can be bought is a paywall with no door: it would take the
    /// free shelf away from everyone already using perch and offer them nothing
    /// to do about it. So the ceiling switches on with the key, in one place,
    /// and this is that place.
    var canSell: Bool { !verifier.publicKey.isEmpty }

    /// How many tiles the shelf may hold, or nil for "as many as you like".
    var capacity: Int? {
        guard canSell, !state.isLicensed else { return nil }
        return Self.freeTierCapacity
    }

    /// How many of `requested` new items fit. Pure, so the suite can pin the
    /// arithmetic without a shelf.
    ///
    /// Counts pending transfers as occupied: files still staging have already
    /// claimed their slots, and admitting more because they haven't landed yet
    /// would let the cap be walked past by dropping fast.
    nonisolated static func admissible(requested: Int, onShelf: Int, capacity: Int?) -> Int {
        guard let capacity else { return requested }
        return max(0, min(requested, capacity - onShelf))
    }

    /// Called by the shelf when a drop had to be trimmed. The message is the
    /// whole marketing funnel, so it is written kindly: it states the fact, it
    /// does not scold, and it never implies anything was lost.
    func noteCapReached(refused: Int) {
        guard refused > 0 else { return }
        noteTask?.cancel()
        capNote = refused == 1
            ? "The free shelf holds \(Self.freeTierCapacity) — one item stayed where it was."
            : "The free shelf holds \(Self.freeTierCapacity) — \(refused) items stayed where they were."
        noteTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled else { return }
            self.capNote = nil
        }
    }

    func clearCapNote() {
        noteTask?.cancel()
        capNote = nil
    }

    // MARK: Copy for the surfaces

    /// One line for the Settings pane and the strip's subtitle.
    var stateDescription: String {
        switch state {
        case .free:
            return "Free — the shelf holds \(Self.freeTierCapacity) items at a time."
        case let .licensed(license):
            let through = Self.formatted(license.coveredThrough)
            return "Licensed to \(license.email) · \(license.seats) seat\(license.seats == 1 ? "" : "s") · updates covered through \(through)."
        case let .uncovered(license):
            let through = Self.formatted(license.coveredThrough)
            return "Licensed to \(license.email), but this build is newer than \(through). Your license still covers every build up to then — renew to take newer ones."
        }
    }

    /// The extra line the update nudge grows when the newer release would land
    /// outside coverage, so nobody updates into a downgrade.
    func renewalHint(forRelease version: String) -> String? {
        guard let license = state.license,
              !license.covers(buildVersion: version)
        else {
            return nil
        }
        return "Covered through \(Self.formatted(license.coveredThrough)) — renew to update."
    }

    private static func formatted(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }
}
