import Foundation
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let showOnAllDisplays = "showOnAllDisplays"
        static let retentionDays = "retentionDays"
        static let mobileEnabled = "mobileEnabled"
        /// One-shot marker for the retention opt-in migration below.
        static let retentionOptInMigrated = "retentionOptInMigrated"
    }

    private let defaults: UserDefaults

    @Published var showOnAllDisplays: Bool {
        didSet { defaults.set(showOnAllDisplays, forKey: Key.showOnAllDisplays) }
    }

    /// How many days an untouched item survives on the shelf — or **0, never**,
    /// which is the default.
    ///
    /// Off by default deliberately. Expiry runs `StagingRepository.prune` →
    /// `FileManager.removeItem`: a permanent delete, not a trip to the Trash,
    /// and there is nowhere recoverable to send it instead — perch is
    /// sandboxed, so its Trash is inside its own container where Finder will
    /// never show it. For drag-promised content, typed text and links, and
    /// anything a paired iPhone sent, **the shelf copy is the only copy**. A
    /// timer that quietly deletes that is the one way perch can lose your work
    /// without ever asking, so it is something you switch on, not something you
    /// have to notice and switch off.
    @Published var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Key.retentionDays) }
    }

    /// Whether this Mac listens for its paired iPhones at all. Off tears the
    /// listener down; pairing stays remembered for when it comes back on.
    @Published var mobileEnabled: Bool {
        didSet { defaults.set(mobileEnabled, forKey: Key.mobileEnabled) }
    }

    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Before `register`, and that ordering is load-bearing: `object(forKey:)`
        // consults the registration domain too, so once the defaults are
        // registered there is no way left to ask "did the user ever actually
        // store this?" — every key answers yes.
        Self.migrateRetentionToOptIn(defaults)
        defaults.register(defaults: [
            Key.showOnAllDisplays: true,
            Key.retentionDays: 0,
            Key.mobileEnabled: true,
        ])
        showOnAllDisplays = defaults.bool(forKey: Key.showOnAllDisplays)
        // `max(0,)`, not `max(1,)` — the old floor made "never" unrepresentable,
        // so a stored 0 silently became a one-day expiry.
        retentionDays = max(0, defaults.integer(forKey: Key.retentionDays))
        mobileEnabled = defaults.bool(forKey: Key.mobileEnabled)
        refreshLaunchAtLogin()
    }

    /// Clears any retention a user chose under the old UI, exactly once.
    ///
    /// Every stored value was chosen against a stepper that said "Discard items
    /// older than N days" and started at **1** — so it never offered "never",
    /// and it never said that discarding is an outright delete with no Trash to
    /// fish it back out of. Someone who wanted the shelf left alone had no way
    /// to say so and may well have parked it at 30 as the nearest thing.
    ///
    /// Consent gathered under a description that wrong isn't consent to this,
    /// so the choice is handed back rather than carried forward: the timer goes
    /// off once, and the Settings pane now describes what turning it on costs.
    /// The marker means this happens on one launch only — set it again
    /// afterwards and the user's new choice stands untouched.
    private static func migrateRetentionToOptIn(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: Key.retentionOptInMigrated) else { return }
        defaults.set(true, forKey: Key.retentionOptInMigrated)
        // Only touches an explicitly stored value. Someone who never opened
        // Settings has no key here, already reads 0, and is left alone.
        guard defaults.object(forKey: Key.retentionDays) != nil else { return }
        defaults.set(0, forKey: Key.retentionDays)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    private func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
