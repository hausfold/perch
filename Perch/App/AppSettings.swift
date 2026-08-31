import Foundation
import ServiceManagement

/// Perch Settings, as SwiftUI sees it.
///
/// A thin face over `ConfigFileStore` — **the files are the source of truth**
/// (`AppConfigFile.swift` lays out which two and in what order), and this type
/// only publishes them and writes the container one back. A switch clicked in
/// Settings and a line typed into `settings.json` are the same act, and an edit
/// made while perch is running lands on screen without a relaunch.
///
/// What is left in `UserDefaults` is what a settings file has no business
/// holding: the pane Settings was last on, the window's frame, the update
/// checker's cache. Ephemera, not settings.
@MainActor
final class AppSettings: ObservableObject {
    /// The `UserDefaults` keys the file-backed builds replaced. Read exactly
    /// once each, by the migration below, and then removed.
    private enum LegacyKey {
        static let showOnAllDisplays = "showOnAllDisplays"
        static let retentionDays = "retentionDays"
        static let mobileEnabled = "mobileEnabled"
        static let automaticUpdateChecks = "automaticUpdateChecks"
        /// One-shot marker for the retention opt-in migration below. Stays in
        /// `UserDefaults`: it records that a migration ran on this Mac, which
        /// is not a setting and would be meaningless in a file someone edits.
        static let retentionOptInMigrated = "retentionOptInMigrated"
        /// The watched folder the "Shelf my screenshots" switch remembered.
        /// That switch is gone — Settings ▸ Watched Folders offers the screenshots
        /// folder and nothing more — so this is removed rather than carried
        /// anywhere: it pointed at one row's security bookmark, and a stale
        /// pointer at a bookmark is exactly the kind of trace perch does not
        /// leave lying around.
        static let screenshotsFolderID = "screenshotsFolderID"
    }

    @Published var showOnAllDisplays: Bool {
        didSet {
            guard !isApplyingFileChange, showOnAllDisplays != oldValue else { return }
            let value = showOnAllDisplays
            commit({ $0.showOnAllDisplays = value }, revert: { self.showOnAllDisplays = oldValue })
        }
    }

    /// How many days an untouched item survives on the shelf — or **0, never**,
    /// which is the default. See `AppConfig.retentionDays` for why the default
    /// is off and why a stored 0 must survive every read intact.
    @Published var retentionDays: Int {
        didSet {
            guard !isApplyingFileChange, retentionDays != oldValue else { return }
            let value = retentionDays
            commit({ $0.retentionDays = value }, revert: { self.retentionDays = oldValue })
        }
    }

    /// Whether this Mac listens for its paired iPhones at all. `MobileReceiver`
    /// follows this publisher, so a file edit tears the listener down or brings
    /// it back exactly like the switch does.
    @Published var mobileEnabled: Bool {
        didSet {
            guard !isApplyingFileChange, mobileEnabled != oldValue else { return }
            let value = mobileEnabled
            commit({ $0.mobileEnabled = value }, revert: { self.mobileEnabled = oldValue })
        }
    }

    /// The hourly release check. `UpdateCheck` reads the store directly rather
    /// than this property — it asks from its own timer, off the main actor.
    @Published var automaticUpdateChecks: Bool {
        didSet {
            guard !isApplyingFileChange, automaticUpdateChecks != oldValue else { return }
            let value = automaticUpdateChecks
            commit({ $0.automaticUpdateChecks = value }, revert: { self.automaticUpdateChecks = oldValue })
        }
    }

    /// macOS's answer, not a stored one: `SMAppService` holds this setting and
    /// perch only asks. A declaration in the rice drop is applied to the system
    /// at launch and whenever that file changes — see `AppConfig.launchAtLogin`.
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginError: String?

    /// Why the last write didn't land, if it didn't. Settings shows it rather
    /// than leaving a switch that moved over a file that didn't.
    @Published private(set) var writeError: String?

    /// The settings the rice drop declares. Republished so the window redraws
    /// its read-only rows when that file changes under a running perch.
    @Published private(set) var declaredKeys: Set<String> = []

    /// Where Settings writes, and where a declaration would come from. Both are
    /// shown in the window: a file-backed app that never names its files is a
    /// file-backed app you can't edit.
    var configFileURL: URL { store.fileURL }
    var declarationURL: URL? { store.declarationURL }

    func isDeclared(_ key: String) -> Bool { declaredKeys.contains(key) }

    private let store: ConfigFileStore
    private let defaults: UserDefaults
    /// True while a change *from the files* is being pushed into the published
    /// properties — without it, applying an external edit would write the same
    /// values straight back out.
    private var isApplyingFileChange = false

    init(store: ConfigFileStore = .shared, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults

        // Order is load-bearing, and both of these run before the first read.
        //
        // The opt-in migration works on `UserDefaults` and has to see it as the
        // old builds left it, so it goes first; whatever it decides is then
        // what the second migration carries into the file. Ordered the other
        // way, a retention chosen under the old wording would reach the file
        // before anything cleared it, and the clearing would then be looking at
        // the wrong copy.
        Self.migrateRetentionToOptIn(defaults)
        Self.migrateFromDefaults(defaults, into: store)
        defaults.removeObject(forKey: LegacyKey.screenshotsFolderID)

        let config = store.current()
        showOnAllDisplays = config.showOnAllDisplays
        retentionDays = config.retentionDays
        mobileEnabled = config.mobileEnabled
        automaticUpdateChecks = config.automaticUpdateChecks
        declaredKeys = store.declaredKeys()

        // The hop drops the snapshot and re-asks. Between the store publishing
        // and this Task running, a click can land — and pushing the older value
        // in afterwards would leave the window showing something no file says,
        // with no further event coming to correct it.
        store.start { [weak self] _ in
            Task { @MainActor in self?.applyLatest() }
        }

        refreshLaunchAtLogin()
        applyDeclaredLaunchAtLogin(store.current().launchAtLogin)
    }

    /// Push whatever the files now say into the published properties, without
    /// writing it back out.
    private func applyLatest() {
        apply(store.current())
    }

    private func apply(_ config: AppConfig) {
        isApplyingFileChange = true
        defer { isApplyingFileChange = false }
        showOnAllDisplays = config.showOnAllDisplays
        retentionDays = config.retentionDays
        mobileEnabled = config.mobileEnabled
        automaticUpdateChecks = config.automaticUpdateChecks
        declaredKeys = store.declaredKeys()
        writeError = nil
        applyDeclaredLaunchAtLogin(config.launchAtLogin)
    }

    /// Write one change through to the file. On failure the published value
    /// goes back to what the file still says — a switch that stays where it was
    /// put while the file disagrees is the one outcome a file-backed settings
    /// window must not produce.
    private func commit(_ mutate: @escaping @Sendable (inout AppConfig) -> Void, revert: () -> Void) {
        if let error = store.update(mutate) {
            writeError = error.localizedDescription
            isApplyingFileChange = true
            revert()
            isApplyingFileChange = false
            return
        }
        writeError = nil
    }

    // MARK: - Launch at login

    /// The switch. Refused while the rice drop declares the answer, which is
    /// belt-and-braces: Settings already renders that row read-only.
    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isDeclared(AppConfig.Key.launchAtLogin) else {
            writeError = ConfigWriteError
                .declared(keys: [AppConfig.Key.launchAtLogin], file: store.declarationURL)
                .localizedDescription
            return
        }
        register(enabled)
    }

    /// A declaration is reasserted on every launch and every edit — that is
    /// what declaring a machine's configuration means, and the row is read-only
    /// so nobody is fighting perch over it in the window.
    ///
    /// Nothing happens when no file names the key: macOS's own answer stands,
    /// including a user having removed perch in System Settings ▸ General ▸
    /// Login Items, which an app that silently put itself back would make a
    /// meaningless pane.
    private func applyDeclaredLaunchAtLogin(_ declared: Bool?) {
        guard let declared, declared != launchAtLogin else { return }
        // An XCTest host *is* Perch.app, run out of DerivedData — registering
        // from there aims the user's Login Items at a build directory.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        register(declared)
    }

    private func register(_ enabled: Bool) {
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

    // MARK: - Migrations

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
    ///
    /// It works on `UserDefaults` alone, and deliberately so: it is about the
    /// builds that stored settings there, and the value it clears is the one
    /// `migrateFromDefaults` is about to carry into the file. A `settings.json`
    /// that already exists has been through this.
    private static func migrateRetentionToOptIn(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: LegacyKey.retentionOptInMigrated) else { return }
        defaults.set(true, forKey: LegacyKey.retentionOptInMigrated)
        // Only touches an explicitly stored value — and nothing registers a
        // default for these keys any more, so `object(forKey:)` still answers
        // the question it is being asked. Someone who never opened Settings has
        // no key here, already reads 0, and is left alone.
        guard defaults.object(forKey: LegacyKey.retentionDays) != nil else { return }
        defaults.set(0, forKey: LegacyKey.retentionDays)
    }

    /// Whatever the `UserDefaults`-backed builds stored, written into
    /// `settings.json` once and then removed from defaults, so there is exactly
    /// one place these live afterwards. A key nobody ever changed is absent
    /// from defaults and stays absent from the file — a default is not a
    /// setting somebody made.
    ///
    /// **A file wins wherever it speaks.** Only keys `settings.json` does not
    /// name are filled in, and a key the rice drop declares is never filled in
    /// at all: a value someone typed into a file — or that their desktop
    /// generated — is a later, more deliberate decision than a switch they
    /// flipped in a previous build, and a migration that overwrote it would
    /// take a machine whose settings are declared and quietly hand it the old
    /// ones instead.
    ///
    /// The legacy keys are cleared once the file has them — or once it is clear
    /// there is nothing to carry — so this can't run twice and can't resurrect a
    /// value the user has since changed in the file. A write that *fails* keeps
    /// them, and the migration is retried next launch: dropping them there would
    /// hand someone who turned the phone listener off a listener that is back on
    /// with the old answer gone.
    private static func migrateFromDefaults(_ defaults: UserDefaults, into store: ConfigFileStore) {
        let legacy: [(key: String, fileKey: String, carry: @Sendable (Bool, Int, inout AppConfig) -> Void)] = [
            (LegacyKey.showOnAllDisplays, AppConfig.Key.showOnAllDisplays, { flag, _, config in
                config.showOnAllDisplays = flag
            }),
            (LegacyKey.retentionDays, AppConfig.Key.retentionDays, { _, number, config in
                config.retentionDays = max(0, number)
            }),
            (LegacyKey.mobileEnabled, AppConfig.Key.mobileEnabled, { flag, _, config in
                config.mobileEnabled = flag
            }),
            (LegacyKey.automaticUpdateChecks, AppConfig.Key.automaticUpdateChecks, { flag, _, config in
                config.automaticUpdateChecks = flag
            }),
        ]
        let stored = legacy.filter { defaults.object(forKey: $0.key) != nil }
        guard !stored.isEmpty else { return }
        let clear = { for entry in stored { defaults.removeObject(forKey: entry.key) } }

        let spokenFor = store.namedKeys().union(store.declaredKeys())
        let fillable = stored.filter { !spokenFor.contains($0.fileKey) }
        guard !fillable.isEmpty else { return clear() }

        // One mutation per key rather than one wholesale assignment: the store
        // applies these to its *container* layer, and handing it a whole
        // `AppConfig` read back out of `current()` would carry the declaration's
        // answers in with them.
        let fills: [@Sendable (inout AppConfig) -> Void] = fillable.map { entry in
            let flag = defaults.bool(forKey: entry.key)
            let number = defaults.integer(forKey: entry.key)
            return { config in entry.carry(flag, number, &config) }
        }
        guard store.update({ config in for fill in fills { fill(&config) } }) == nil else { return }
        clear()
    }
}
