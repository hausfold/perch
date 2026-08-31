import Foundation
import os.log

// MARK: - The settings themselves

/// Every switch in Perch Settings, as it lives on disk.
///
/// **A file is the source of truth, not `UserDefaults`.** Two files, in fact,
/// and the order between them is the whole design:
///
/// ```text
/// compiled-in defaults
///   ‹ ~/Library/Containers/…/Application Support/Perch/settings.json   ← Settings writes this
///     ‹ ~/.config/perch/config.json                                     ← the rice declares this
/// ```
///
/// Settings writes the **container** file, which perch owns outright and needs
/// no entitlement to touch. The rice drop layers on top: any key it names wins,
/// and Settings renders that row read-only saying where the value comes from.
/// Perch never writes the rice drop — its sandbox exception for
/// `~/.config/perch/` is read-only and stays that way, because widening it to
/// read-write is the kind of temporary exception App Review reads as a
/// sandbox that isn't one. Declaring a setting is therefore a machine-level
/// act (`haus rebuild`, or a text editor), exactly like declaring the theme.
///
/// `UserDefaults` keeps only what a settings file has no business holding:
/// which pane Settings was last on, the Settings window's frame, and the update
/// checker's cache of what GitHub last said — none of which means anything to a
/// human reading a config file.
struct AppConfig: Equatable, Sendable {
    /// A shelf at the notch of every screen. On by default: a drop target that
    /// isn't on the display you're dragging on is a drop target that isn't
    /// there.
    var showOnAllDisplays = true

    /// How many days an untouched item survives — or **0, never**, which is
    /// the default.
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
    var retentionDays = 0

    /// Whether this Mac listens for its paired iPhones at all. Off tears the
    /// listener down; pairing stays remembered for when it comes back on.
    var mobileEnabled = true

    /// The hourly release check. Defaults on; a user-initiated check ignores
    /// it, because asking is consent.
    var automaticUpdateChecks = true

    /// **Declaration only, and nil is the normal case.** macOS holds the real
    /// answer (`SMAppService.mainApp.status`), so unlike every other key here
    /// there is nothing for perch to store — a copy in a file could only
    /// disagree with the system. What a file *can* do is declare the intent,
    /// which is what a rice is for: name it in `~/.config/perch/config.json`
    /// and perch registers or unregisters the login item to match on every
    /// launch, and Settings shows the switch read-only.
    ///
    /// Perch never writes this key. An app that put itself back into Login
    /// Items because a file it wrote said so is the exact thing that makes
    /// System Settings ▸ General ▸ Login Items untrustworthy; nothing is
    /// reasserted unless a human declared it somewhere they can see.
    var launchAtLogin: Bool?

    /// The JSON key for each setting. Spelled the way someone typing the file
    /// by hand would spell it — these names are user-facing surface, so
    /// renaming one silently drops whatever a user already wrote.
    ///
    /// They are also the legacy `UserDefaults` key names, which is not a
    /// coincidence: `AppSettings.migrateFromDefaults` reads the old key and
    /// writes the new one, and keeping the spelling means a hand-written
    /// `defaults write` from someone's notes still names the same thing.
    enum Key {
        static let showOnAllDisplays = "showOnAllDisplays"
        static let retentionDays = "retentionDays"
        static let mobileEnabled = "mobileEnabled"
        static let automaticUpdateChecks = "automaticUpdateChecks"
        static let launchAtLogin = "launchAtLogin"

        /// Every key perch reads as a setting.
        ///
        /// What makes it necessary: the rice drop is a *shared* file. It
        /// already carries `themeDark`, `themeLight`, `accent` and
        /// `screenshotsFolder`, and it will carry more. Locking a Settings row
        /// because the file names *some* key would grey out the whole window
        /// on every haus desktop; the intersection with this set is what
        /// "declared" actually means.
        static let all: Set<String> = [
            showOnAllDisplays, retentionDays, mobileEnabled, automaticUpdateChecks, launchAtLogin,
        ]
    }

    init() {}

    /// Read from a decoded JSON object, keeping `defaults` for anything the
    /// object doesn't name.
    ///
    /// A partial file is the normal case — the point of a settings file is
    /// that you write the one line you care about — and the `defaults`
    /// parameter is also how the two layers compose: decode the container file
    /// over the compiled-in defaults, then the rice drop over that, and
    /// precedence falls out of the same three lines.
    init(json: [String: Any], defaults: AppConfig = AppConfig()) {
        self = defaults
        if let value = json[Key.showOnAllDisplays] as? Bool { showOnAllDisplays = value }
        // `max(0,)`, not `max(1,)` — a floor of one day makes "never"
        // unrepresentable, so a stored 0 silently becomes a one-day expiry,
        // which is the most destructive value on the menu.
        if let value = json[Key.retentionDays] as? Int { retentionDays = max(0, value) }
        if let value = json[Key.mobileEnabled] as? Bool { mobileEnabled = value }
        if let value = json[Key.automaticUpdateChecks] as? Bool { automaticUpdateChecks = value }
        if let value = json[Key.launchAtLogin] as? Bool { launchAtLogin = value }
    }

    /// Every key perch writes, at its current value — the merge payload for a
    /// write. Written in full rather than as a delta so the file is
    /// self-documenting: open it and every switch perch has is in there.
    ///
    /// `launchAtLogin` is deliberately absent; see the property.
    var json: [String: Any] {
        [
            Key.showOnAllDisplays: showOnAllDisplays,
            Key.retentionDays: retentionDays,
            Key.mobileEnabled: mobileEnabled,
            Key.automaticUpdateChecks: automaticUpdateChecks,
        ]
    }

    /// Which settings differ between two configs, by file key. What lets a
    /// write be refused for naming a declared key *before* anything moves.
    static func changedKeys(from old: AppConfig, to new: AppConfig) -> Set<String> {
        var keys: Set<String> = []
        if old.showOnAllDisplays != new.showOnAllDisplays { keys.insert(Key.showOnAllDisplays) }
        if old.retentionDays != new.retentionDays { keys.insert(Key.retentionDays) }
        if old.mobileEnabled != new.mobileEnabled { keys.insert(Key.mobileEnabled) }
        if old.automaticUpdateChecks != new.automaticUpdateChecks {
            keys.insert(Key.automaticUpdateChecks)
        }
        if old.launchAtLogin != new.launchAtLogin { keys.insert(Key.launchAtLogin) }
        return keys
    }
}

// MARK: - The store

/// Loads both settings files, follows them, and writes the container one back.
///
/// Thread-safe by one serial queue, because the answer is wanted from three
/// places at once: SwiftUI on the main actor, `UpdateCheck` from its timer, and
/// the file-system sources themselves.
///
/// `update` is deliberately **synchronous**, so a click from the main actor
/// waits out one small JSON write. That is not the blocking file work perch's
/// invariant is about — that rule is for importing: copies, cloud waits and
/// coordinated reads of files someone else owns, which are unbounded and can
/// take minutes. This is a few hundred bytes into the app's own container, and
/// buying an async write would cost the thing that makes the window honest:
/// the caller learns whether the file took the change in time to put the switch
/// back if it didn't.
final class ConfigFileStore: @unchecked Sendable {
    static let shared = ConfigFileStore(
        file: defaultFileURL(),
        declaration: RiceFiles.configFile
    )

    private let file: URL
    private let declaration: URL?
    private let queue = DispatchQueue(label: "com.hausfold.perch.config")

    /// What perch answers with: the container file with the declaration
    /// layered over it.
    private var config = AppConfig()
    /// The container layer **alone** — what perch's own file says, before the
    /// declaration is applied.
    ///
    /// Kept apart from `config` because it is what gets written back. Writing
    /// the composed value instead would copy the rice's answers into the user's
    /// own file on the first unrelated toggle, and they would then outlive the
    /// declaration that put them there: remove the rice's key and the setting
    /// would not come back, it would stay stuck at whatever the rice last said.
    /// For `retentionDays` that turns "the machine declares 30 days" into "this
    /// user chose to have their shelf deleted on a timer", permanently, without
    /// anyone deciding it.
    private var own = AppConfig()
    /// Every key the *container* file had, decoded but not interpreted. A
    /// write merges into this rather than replacing it, so a key perch doesn't
    /// know — something a newer build writes, or a note someone left in there
    /// — survives a toggle instead of being quietly deleted.
    private var raw: [String: Any] = [:]
    /// The same for the rice drop, which perch reads and never writes. Kept
    /// whole because the theme keys live in it too and none of them are ours.
    private var declared: [String: Any] = [:]

    private let fileWatch: FileWatch
    private let declarationWatch: FileWatch
    private var observer: (@Sendable (AppConfig) -> Void)?

    private static let log = Logger(subsystem: "com.hausfold.perch", category: "Settings")

    init(file: URL, declaration: URL?) {
        self.file = file
        self.declaration = declaration
        fileWatch = FileWatch(queue: queue)
        declarationWatch = FileWatch(queue: queue)
        queue.sync { load() }
    }

    /// The current settings. Callable from anywhere, including off the main
    /// actor.
    func current() -> AppConfig {
        queue.sync { config }
    }

    /// Where Settings writes. Shown in the window, because a file-backed app
    /// that never tells you the path is a file-backed app you can't edit — and
    /// this one is buried in the sandbox container, where nobody would look.
    var fileURL: URL { file }

    /// Where a declaration would come from, named in the read-only note so the
    /// answer to "why can't I change this" is on screen next to the switch.
    var declarationURL: URL? { declaration }

    /// The settings the rice drop names — the ones Settings renders read-only.
    /// Intersected with `AppConfig.Key.all`, so the theme keys that share that
    /// file lock nothing.
    func declaredKeys() -> Set<String> {
        queue.sync { Set(declared.keys).intersection(AppConfig.Key.all) }
    }

    func isDeclared(_ key: String) -> Bool {
        queue.sync { declared[key] != nil }
    }

    /// The keys the container file itself names, whatever their values. What
    /// separates "the user set this to false" from "the file is silent, so it
    /// defaults to false" — the only way the `UserDefaults` migration can fill
    /// the gaps without overwriting a decision somebody already wrote down.
    func namedKeys() -> Set<String> {
        queue.sync { Set(raw.keys) }
    }

    /// Start following both files. Separate from `init` so a test can
    /// construct a store against a temp file without arming a watcher.
    ///
    /// `onChange` fires only when the composed settings actually *differ* from
    /// what the store already holds, which is what makes perch's own writes
    /// silent: the write lands, the watcher fires, the reload finds the same
    /// values, and nothing is republished. No echo, no flag, no race.
    func start(onChange: @escaping @Sendable (AppConfig) -> Void) {
        queue.sync {
            observer = onChange
            load()
            fileWatch.follow(file) { [weak self] in self?.load() }
            if let declaration {
                declarationWatch.follow(declaration) { [weak self] in self?.load() }
            }
        }
    }

    /// Apply a change and write the whole container file back. Returns the
    /// error if it didn't land, so Settings can say so rather than showing a
    /// switch that moved and a file that didn't.
    @discardableResult
    func update(_ mutate: @Sendable (inout AppConfig) -> Void) -> Error? {
        queue.sync {
            // Asked against the COMPOSED value, because that is what the caller
            // saw: someone dragging a declared row back to where their own file
            // already has it is still asking for a change, and answering "no
            // change to make" would report success while the window kept showing
            // the declaration.
            var requested = config
            mutate(&requested)
            let changed = AppConfig.changedKeys(from: config, to: requested)
            guard !changed.isEmpty else { return nil }
            // Refused BEFORE anything in memory moves. A store that accepted
            // the change and only failed the write would answer `current()`
            // with a value the files reject — and the second click, seeing no
            // change left to make, would report success. A read-only row that
            // sticks on the second try is worse than one that never moves.
            let blocked = changed.intersection(Set(declared.keys))
            guard blocked.isEmpty else {
                return ConfigWriteError.declared(keys: blocked.sorted(), file: declaration)
            }
            // Applied against the CONTAINER layer, which is the only thing that
            // gets written. Nothing declared is in `changed` by now, so for
            // every key that moved the two layers agreed anyway — and every key
            // that didn't move keeps whatever perch's own file said, rather than
            // inheriting the declaration's answer.
            var updated = own
            mutate(&updated)
            do {
                try write(updated)
                own = updated
                config = AppConfig(json: declared, defaults: own)
                return nil
            } catch {
                Self.log.error("settings.json write failed: \(error.localizedDescription, privacy: .public)")
                return error
            }
        }
    }

    // MARK: - Disk

    private func load() {
        // Each file keeps its previous contents on a parse failure, separately:
        // a typo in one is no reason to drop what the other still says.
        raw = decode(file, previous: raw, label: "settings.json")
        if let declaration {
            declared = decode(declaration, previous: declared, label: "config.json")
        }
        own = AppConfig(json: raw)
        let composed = AppConfig(json: declared, defaults: own)
        guard composed != config else { return }
        config = composed
        observer?(composed)
    }

    private func decode(_ url: URL, previous: [String: Any], label: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else {
            // No file is not an error — it means every setting it could have
            // named is at whatever the layer underneath says, which is exactly
            // what an absent key already means.
            return [:]
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        else {
            // A typo must never turn perch's switches off underneath someone
            // — least of all `retentionDays`, where the default is the safe
            // value but a *reverted* choice is not what they asked for.
            Self.log.error("\(label, privacy: .public) isn't a JSON object — keeping the previous settings")
            return previous
        }
        return json
    }

    private func write(_ config: AppConfig) throws {
        var merged = raw
        for (key, value) in config.json { merged[key] = value }
        let data = try JSONSerialization.data(
            withJSONObject: merged,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Atomic, so a reader (perch's own watcher included) never sees a
        // half-written file. The rename that makes it atomic is also what the
        // watcher has to re-arm after — `FileWatch` handles that.
        try (data + Data("\n".utf8)).write(to: file, options: .atomic)
        raw = merged
        fileWatch.rearm()
    }

    /// `~/Library/Containers/…/Application Support/Perch/settings.json` under
    /// the sandbox — beside `watched-folders.json` and the staging repository,
    /// in the one directory perch can write without asking anybody.
    ///
    /// A `bench try` dev build signs under `com.hausfold.perch.dev` and so gets
    /// its own container, its own settings and its own shelf — the same
    /// separation the update checker's state already has.
    static func defaultFileURL() -> URL {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return FileManager.default.temporaryDirectory
                .appending(path: "Perch", directoryHint: .isDirectory)
                .appending(path: "settings.json")
        }
        return support
            .appending(path: "Perch", directoryHint: .isDirectory)
            .appending(path: "settings.json")
    }
}

/// Why a write didn't land.
enum ConfigWriteError: LocalizedError, Equatable {
    /// The rice drop names this setting, so perch's copy of it is not the one
    /// that counts. Refused rather than written, because a write that landed
    /// would be overruled by the very next read — a switch that moves and
    /// springs back is worse than one that never moves.
    case declared(keys: [String], file: URL?)

    var errorDescription: String? {
        switch self {
        case let .declared(keys, file):
            let names = keys.joined(separator: ", ")
            let path = file.map { RiceFiles.abbreviate($0.path) } ?? "your config file"
            return "\(names) comes from \(path) — change it there."
        }
    }
}

// MARK: - Following a file

/// One file-system source, re-armed as often as it takes.
///
/// Two things make this more than a `DispatchSource` wrapper. An atomic write
/// replaces the inode, so the descriptor a watcher holds stops being the file
/// it was watching the first time anybody — perch included — saves it. And the
/// file may not exist yet: on a standalone install `~/.config/perch/config.json`
/// never has, and a `haus rebuild` creating it should reach a running perch
/// rather than wait for the next launch. So a file that isn't there is watched
/// through its **directory** until it is.
///
/// One level, and no further: when `~/.config/perch/` itself doesn't exist the
/// only place left to watch is `~/.config`, which is outside the read-only
/// sandbox exception and would be denied. A declaration written into a
/// directory that had to be created for it therefore lands on the next launch
/// rather than immediately — the one case this can't follow, and the cheapest
/// possible one to live with.
///
/// Every method runs on the store's serial queue, which is also the queue the
/// event handlers fire on.
private final class FileWatch {
    private let queue: DispatchQueue
    private var source: DispatchSourceFileSystemObject?
    private var url: URL?
    private var handler: (() -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit {
        // Ownership of the descriptor is the cancel handler's, so cancelling is
        // also what closes it. Nothing in the app outlives its store, but a
        // test suite makes one per test.
        source?.cancel()
    }

    func follow(_ url: URL, handler: @escaping () -> Void) {
        self.url = url
        self.handler = handler
        arm()
    }

    /// Re-arm after perch's own write. Not a no-op even when nothing looks
    /// wrong: the file may not have existed when this armed (so it is holding
    /// the *directory*), and the atomic write replaced the inode either way.
    func rearm() {
        guard url != nil else { return }
        arm()
    }

    private func arm() {
        // `cancel()` is asynchronous and its handler runs on this very queue,
        // so it cannot have closed the old descriptor by the time we return —
        // which is why the fd is NOT closed here. `open` below would be handed
        // the same number straight back, and the stale handler would then close
        // the new watcher out from under us (or, worse, whatever else took that
        // number in between). Ownership passes to the cancel handler.
        source?.cancel()
        source = nil
        guard let url, let handler else { return }

        var descriptor = open(url.path, O_EVTONLY)
        if descriptor < 0 {
            descriptor = open(url.deletingLastPathComponent().path, O_EVTONLY)
        }
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            handler()
            // Unconditional, because every event this asked for can have made
            // the descriptor stale: a rename swapped the inode, a delete took
            // it, and a directory write may be the file finally appearing —
            // the one case where the watch has to move from the directory to
            // the file itself.
            self?.arm()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }
}
