import AppKit
import Foundation
import os

// MARK: - Update check (hourly release poll + cohort-aware nudge)
//
// Perch ships through four doors — the rice (a Nix-built, notarized bundle the
// activation script copies to /Applications), a Homebrew cask, a drag-install
// from the release ZIP, and a bare Nix store path — so the nudge's one job is to
// name the RIGHT next step for THIS install rather than hand everyone the same
// button.
//
// Ported from pounce's `UpdateNudge`: same hourly poll, same per-version
// dismissal, same CalVer ordering — with two deliberate differences, both
// shaped by **the app sandbox**:
//
//   apply    three cohorts are owned by something that already updates them, so
//            they get an instruction — the exact command for this install, on
//            the pasteboard. The fourth, a ZIP dragged into /Applications, has
//            no such owner, and telling it to download and drag again was the
//            worst step in perch. It now installs in one click, but NOT from
//            this process: `ENABLE_APP_SANDBOX = YES`, /Applications is outside
//            the container, and a child process inherits the sandbox. The swap
//            is done by `PerchUpdater.app`, nested in this bundle and launched
//            through LaunchServices, which does not pass the sandbox on. See
//            `SelfUpdate.swift`. Nothing in THIS file writes outside the
//            container, and nothing shells out.
//   surface  the obvious surface is a UNUserNotificationCenter banner. Perch
//            asks the system for no permissions it can avoid (see the Mission
//            Control note in the rice's modules/shelf) and notifications are one
//            of them, so the only surfaces are passive: a strip at the bottom of
//            the expanded shelf, and a row in the menu bar menu. Neither
//            interrupts anything; both wait until you look.
//
// Network: one unauthenticated GitHub API call per hour, carrying nothing but an
// IP and a user-agent, off by a Settings toggle — plus, only when someone clicks
// Update on a drag install, the release ZIP itself. Never runs in DEBUG builds.
// This is the only reason `com.apple.security.network.client` is in the
// entitlements — perch reaches for exactly one host, and only to read a tag.

// MARK: - InstallKind

/// How THIS install takes an update — decides the hint, the button, and the
/// command the button copies.
enum InstallKind: String, Codable, Equatable, CaseIterable {
    /// Homebrew cask — `brew` owns the version.
    case homebrew
    /// Dragged out of the release ZIP — nothing upstream owns this copy, so
    /// perch installs it itself (`SelfUpdate.swift`).
    case direct
    /// The haus desktop's activation copy — `haus update`.
    case rice
    /// A bare Nix store path (`nix run`, someone else's flake) — flake update.
    case nix
    case unknown

    /// The strip's subtitle: what to DO, in this install's own vocabulary.
    var actionHint: String {
        switch self {
        case .homebrew: return "Run brew upgrade --cask perch, then reopen Perch"
        case .direct: return "Install it now — Perch downloads it and reopens"
        case .rice: return "Run haus update in a terminal to pick it up"
        case .nix: return "Update your perch flake input to pick it up"
        case .unknown: return "Open the release page to download it"
        }
    }

    /// What the strip's action button says.
    var buttonLabel: String {
        switch self {
        case .homebrew, .rice, .nix: return "Copy Command"
        case .direct: return "Update Now"
        case .unknown: return "Open Releases"
        }
    }

    /// Whether perch may replace this copy of itself. Only the cohort that owns
    /// its own bytes: a rice or cask install swapped from under its package
    /// manager would be reverted by the next `haus update` or `brew upgrade`,
    /// and a Nix store path is read-only besides. `.unknown` is left out
    /// because it is, by definition, a copy running from somewhere perch cannot
    /// reason about.
    var canSelfUpdate: Bool { self == .direct }

    /// The command `Copy Command` puts on the pasteboard, or nil for the two
    /// cohorts that get the release page instead.
    var updateCommand: String? {
        switch self {
        case .homebrew: return "brew upgrade --cask perch"
        case .rice: return "haus update"
        case .nix: return "nix flake update perch"
        case .direct, .unknown: return nil
        }
    }

    /// The cohort's name, for anywhere a person reads it.
    ///
    /// `rawValue` is a code identifier and two of the five are wrong in prose:
    /// **`rice` is the old word for a desktop** and the workshop's naming rule
    /// keeps it out of anything new a reader sees, and `unknown` reads as a
    /// malfunction rather than as a cohort. Every other user-facing use of this
    /// enum already goes through a written label (`actionHint`, `settingsNote`,
    /// `buttonLabel`); this is the one for the bug-report block, which is the
    /// first place the cohort is quoted into text somebody else reads — a
    /// public GitHub issue.
    var displayName: String {
        switch self {
        case .homebrew: return "Homebrew cask"
        case .direct: return "release ZIP"
        case .rice: return "haus desktop"
        case .nix: return "Nix store path"
        case .unknown: return "install not recognised"
        }
    }

    /// One line for Settings, so the toggle's copy matches what the shelf offers.
    var settingsNote: String {
        switch self {
        case .homebrew: return "Installed with Homebrew — updates come from brew upgrade --cask perch."
        case .direct: return "Installed from the release ZIP — Perch installs its own updates."
        case .rice: return "Installed by the haus desktop — updates come from haus update."
        case .nix: return "Running from the Nix store — updates come from your flake input."
        case .unknown: return "Updates open the GitHub release page."
        }
    }

    // MARK: Detection
    //
    // Path prefixes alone can't tell the cohorts apart: the rice copies the
    // bundle to `/Applications/Perch.app` (modules/shelf, postActivation) and a
    // cask's `app` stanza MOVES it to the same path — so rice, cask, and
    // drag-install are byte-identical locations. Out-of-band receipts break the
    // tie:
    //
    //   rice   /Library/Application Support/haus/perch.installed-from —
    //          written by the activation script with the store path it copied.
    //   cask   <brew prefix>/Caskroom/perch — brew's own staging directory,
    //          which survives the app being moved to /Applications.
    //
    // Both of those live outside perch's container, so under the sandbox the
    // reads may simply be denied — `fileExists` then answers false for a receipt
    // that is really there. That is why there is a third, always-readable
    // signal: `~/.config/perch/config.json`, the rice's theme drop, which the
    // entitlements already grant read access to (RicePalette.swift). It is only
    // consulted when neither receipt could be seen, and it only ever promotes an
    // ambiguous /Applications install from `.direct` to `.rice` — the cohort
    // whose advice (`haus update`) is the one that would otherwise be missed on
    // this machine.

    /// Where the desktop records the store path it installed from.
    static let riceMarkerPaths = [
        "/Library/Application Support/haus/perch.installed-from"
    ]

    /// Homebrew's per-cask staging directory, on both Apple Silicon and Intel.
    static let caskReceiptPaths = [
        "/opt/homebrew/Caskroom/perch",
        "/usr/local/Caskroom/perch",
    ]

    /// Pure so the suite can exercise every cohort without a bundle or a Mac in
    /// that state. Symlinks are resolved by the caller.
    static func detect(
        bundlePath: String,
        home: String,
        hasRiceMarker: Bool,
        hasCaskReceipt: Bool,
        hasRiceThemeDrop: Bool = false
    ) -> InstallKind {
        if bundlePath.hasPrefix("/nix/store/") { return .nix }
        // Still honoured if a cask is ever run straight out of the Caskroom.
        if bundlePath.contains("/Caskroom/perch") { return .homebrew }

        let installed = bundlePath.hasPrefix("/Applications/")
            || bundlePath.hasPrefix(home + "/Applications/")
        guard installed else { return .unknown }

        // The rice reinstalls on every activation, so its marker outranks a
        // leftover cask receipt from a machine that has been both.
        if hasRiceMarker, bundlePath == "/Applications/Perch.app" { return .rice }
        if hasCaskReceipt { return .homebrew }
        // Sandbox fallback: neither receipt was readable. A rice theme drop at
        // the rice's own install path means the rice put this here.
        if hasRiceThemeDrop, bundlePath == "/Applications/Perch.app" { return .rice }
        return .direct
    }

    static func detectLive(fileManager: FileManager = .default) -> InstallKind {
        let hasRiceMarker = riceMarkerPaths.contains { fileManager.fileExists(atPath: $0) }
        let hasCaskReceipt = caskReceiptPaths.contains { fileManager.fileExists(atPath: $0) }
        return detect(
            bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            // NOT `homeDirectoryForCurrentUser`: under the sandbox that answers
            // with the container, and `~/Applications` would never match.
            // RiceFiles.home reads the real one out of the passwd entry.
            home: RiceFiles.home.path,
            hasRiceMarker: hasRiceMarker,
            hasCaskReceipt: hasCaskReceipt,
            hasRiceThemeDrop: !hasRiceMarker && !hasCaskReceipt
                && fileManager.fileExists(atPath: RiceFiles.configFile.path)
        )
    }
}

// MARK: - UpdateCheck

@MainActor
final class UpdateCheck: ObservableObject {
    static let shared = UpdateCheck()

    /// Newer-than-running release ("2026.08.05", no leading v), or nil.
    @Published private(set) var availableVersion: String?
    /// The version the user waved off, persisted. Per-version on purpose:
    /// dismissing 2026.08.05 says nothing about 2026.08.06.
    @Published private(set) var dismissedVersion: String?
    /// Transient line shown in the strip — a user-initiated check's answer, the
    /// confirmation that a command was copied, or how the last install went.
    /// Nil most of the time.
    @Published private(set) var statusNote: String?
    /// Non-nil only while a drag install is installing itself: the step, and a
    /// fraction for the one step that has a length. The strip shows it in place
    /// of the hint, and disables the button.
    @Published private(set) var installPhase: SelfUpdate.Phase?

    private let logger = Logger(subsystem: "com.hausfold.perch", category: "Update")
    private var fetching = false
    private var didStart = false
    private var timer: Timer?
    private var noteTask: Task<Void, Never>?

    nonisolated static let endpoint = URL(string: "https://api.github.com/repos/hausfold/perch/releases/latest")!
    /// Hourly: the nudge should show up the day a release is cut, not a day late.
    nonisolated static let maxAge: TimeInterval = 3600
    nonisolated static let releasesURL = URL(string: "https://github.com/hausfold/perch/releases/latest")!

    /// The feel-test door for the one-click install (`SelfUpdate.swift`).
    /// Clicking the strip's button is the only other way in, and a click means
    /// a shelf on someone's notch — so a hands-on pass in a VM sets this
    /// instead: perch checks once on launch and installs what it finds.
    ///
    /// It reaches a process that inherits your shell or an `open --env`, never
    /// a plain `open -a` (launchd's environment has nothing in it) — the same
    /// door `PERCH_ALLOW_MULTIPLE` uses, and the same limits.
    /// See docs/feel-testing.md.
    static var installsOnLaunch: Bool {
        ProcessInfo.processInfo.environment["PERCH_UPDATE_ON_LAUNCH"] == "1"
    }

    /// Settings toggle (`Updates` section). Defaults on; user-initiated checks
    /// ignore it, because asking is consent.
    ///
    /// Asked of the settings store, not of this object: the hourly timer fires
    /// wherever it likes and the store answers from any thread, where an
    /// `@MainActor` property would need a hop to read a `Bool`.
    static var automaticChecksEnabled: Bool {
        ConfigFileStore.shared.current().automaticUpdateChecks
    }

    var perchVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !version.isEmpty,
           version != "$(MARKETING_VERSION)" {
            return version
        }
        return "dev"
    }

    lazy var installKind: InstallKind = .detectLive()

    // MARK: Pure rules

    nonisolated static func shouldPin(available: String?, dismissed: String?) -> Bool {
        guard let available else { return false }
        return available != dismissed
    }

    var pendingVersion: String? {
        Self.shouldPin(available: availableVersion, dismissed: dismissedVersion)
            ? availableVersion : nil
    }

    /// A build that isn't a release: an Xcode build (whose `MARKETING_VERSION`
    /// is still the project's placeholder) or a `bench try` branch build (a
    /// `-dev` suffix). They must never be nudged — the "update" would offer to
    /// replace the branch being feel-tested with the last release.
    ///
    /// Anything not shaped like CalVer counts, which is what catches the
    /// placeholder: a plain string compare would read "0.1.0" as older than
    /// every release and nudge every debug build forever.
    nonisolated static func isDevVersion(_ version: String) -> Bool {
        CalVer.isDev(version)
    }

    /// CalVer ordering — the rules themselves are `CalVer` in
    /// `UpdateHandoff.swift`, so the updater's downgrade refusal and this
    /// nudge cannot disagree about which build is newer.
    nonisolated static func isNewer(_ candidate: String, than running: String) -> Bool {
        CalVer.isNewer(candidate, than: running)
    }

    // MARK: Lifecycle

    /// Called once from `AppRuntime.start()`. Checks now, then hourly, then on
    /// wake — perch is an accessory app that stays running for weeks, so the lid
    /// being shut is the gap the timer alone can't close.
    func start() {
        guard !didStart else { return }
        didStart = true
        // If this launch is the one the updater asked for, say so — otherwise a
        // one-click update is indistinguishable from perch having crashed and
        // come back.
        if let result = SelfUpdate.consumeResult() {
            note(result.message, transient: result.succeeded)
        }
        // User-initiated when the feel-test hook is set: it has to run in a
        // Debug build too, and asking for it IS the consent the flag stands in
        // for.
        checkForUpdates(userInitiated: Self.installsOnLaunch)
        let timer = Timer.scheduledTimer(withTimeInterval: Self.maxAge, repeats: true) { _ in
            Task { @MainActor in UpdateCheck.shared.checkForUpdates() }
        }
        timer.tolerance = 300
        self.timer = timer
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Cheap: a cached answer inside the hour never touches the network.
            MainActor.assumeIsolated { UpdateCheck.shared.checkForUpdates() }
        }
    }

    func dismiss() {
        guard let v = availableVersion else { return }
        dismissedVersion = v
        var state = Self.readState()
        state.latest = state.latest ?? v
        state.dismissed = v
        Self.writeState(state)
    }

    /// Set when a one-click install failed on this run. It only downgrades the
    /// button to the release page — the next launch offers the click again,
    /// because most failures here (GitHub unreachable, /Applications not yours
    /// today) are temporary.
    @Published private(set) var selfUpdateFailed = false

    /// What the strip and Settings put on the button, now that one cohort's
    /// answer depends on whether its last attempt worked.
    var actionButtonLabel: String {
        if installKind.canSelfUpdate, !SelfUpdate.isAvailable || selfUpdateFailed {
            return "Open Releases"
        }
        return installKind.buttonLabel
    }

    /// Clears the transient note (the strip's ✕ when nothing is pending).
    func clearNote() {
        noteTask?.cancel()
        statusNote = nil
    }

    func checkForUpdates(userInitiated: Bool = false) {
        if !userInitiated {
            // A debug build is either unversioned or a branch build; nudging it
            // would offer to replace the thing being tested.
            #if DEBUG
            return
            #else
            guard Self.automaticChecksEnabled, !Self.isDevVersion(perchVersion) else { return }
            #endif
        }
        guard !fetching else { return }

        let cached = Self.readState()
        if !userInitiated, let checkedAt = cached.checkedAt,
           Date().timeIntervalSince1970 - checkedAt < Self.maxAge {
            // Fresh enough: surface the cached answer, skip the network. Keeps
            // the ORIGINAL checkedAt — restamping here would push the next fetch
            // out by an hour on every launch and, for someone who restarts
            // often, mean the check never actually runs.
            apply(latest: cached.latest, previous: cached, checkedAt: checkedAt, userInitiated: false)
            return
        }

        fetching = true
        if userInitiated { note("Checking for updates…", transient: false) }

        var req = URLRequest(url: Self.endpoint)
        req.setValue("perch-update-check", forHTTPHeaderField: "user-agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            var latest: String?
            if let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = obj["tag_name"] as? String {
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                // The tag reaches the UI and, for the two cohorts that get a
                // release URL, LaunchServices — accept nothing beyond
                // CalVer-shaped characters.
                if version.range(of: "^[0-9][0-9.\\-]*$", options: .regularExpression) != nil {
                    latest = version
                }
            }
            let message = error?.localizedDescription

            Task { @MainActor in
                guard let self else { return }
                self.fetching = false
                guard let latest else {
                    // Network/API miss: stamp nothing, so the next check retries
                    // instead of sitting out the hour on a failure.
                    self.logger.debug("update: no usable tag from GitHub")
                    if userInitiated {
                        self.note(message ?? "Couldn't reach GitHub to check for updates")
                    }
                    return
                }
                self.apply(
                    latest: latest,
                    previous: Self.readState(),
                    checkedAt: Date().timeIntervalSince1970,
                    userInitiated: userInitiated
                )
            }
        }.resume()
    }

    // MARK: Applying
    //
    // Nothing here installs anything. Perch is sandboxed: it cannot replace its
    // own bundle in /Applications, and a `brew` spawned from here would inherit
    // the same sandbox and fail. So the action is always advice — the exact
    // command for this cohort, on the pasteboard, or the release page.

    func performUpdate() {
        // The drag-install cohort installs it here and now. Everything the
        // sandbox forbids happens in `PerchUpdater.app`, which this hands off to
        // just before quitting — see SelfUpdate.swift.
        // `selfUpdateFailed` is what makes the second click do what the button
        // now says: once an install has failed on this run, the button reads
        // Open Releases, and this must not quietly try again behind it.
        if installKind.canSelfUpdate, SelfUpdate.isAvailable, !selfUpdateFailed,
           let version = pendingVersion {
            clearNote()
            installPhase = SelfUpdate.Phase(text: "Starting…", progress: nil)
            SelfUpdate.shared.begin(version: version) { [weak self] phase in
                guard let self else { return }
                guard !phase.isFailure else {
                    // Back to advice: the strip's button becomes Open Releases,
                    // and the reason is on screen rather than in a log.
                    self.installPhase = nil
                    self.selfUpdateFailed = true
                    self.note(phase.text, transient: false)
                    return
                }
                self.installPhase = phase
            }
            return
        }
        if let command = installKind.updateCommand {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            note("Copied '\(command)' — run it in a terminal")
        } else {
            NSWorkspace.shared.open(Self.releasesURL)
            note("Opened the release page")
        }
    }

    /// Reconcile one answer (cached or freshly fetched) into the in-memory
    /// nudge and the stored state.
    private func apply(latest: String?, previous: State, checkedAt: TimeInterval, userInitiated: Bool) {
        guard let latest else { return }
        // Rehydrate the dismissal before deciding anything: a relaunch must not
        // resurrect a nudge the user already waved off.
        dismissedVersion = previous.dismissed

        var state = previous
        state.checkedAt = checkedAt
        state.latest = latest

        guard Self.isNewer(latest, than: perchVersion) else {
            // Up to date, or ahead of the last tag (a branch build). Clear any
            // stale nudge and remember the answer so the next hour is a no-op.
            availableVersion = nil
            Self.writeState(state)
            if userInitiated {
                note(Self.isDevVersion(perchVersion)
                    ? "Latest release is \(latest) — this is a dev build"
                    : "Perch \(perchVersion) is the latest ✅")
            }
            return
        }

        availableVersion = latest
        // Every condition `performUpdate` needs to take the INSTALL branch. Not
        // just tidiness: without them it falls through to the advice branch,
        // and `.direct` has no command to copy — so a dismissed version, or a
        // second pass after a failure, would open a browser window on a machine
        // this flag exists to keep hands off.
        if Self.installsOnLaunch, installKind.canSelfUpdate, SelfUpdate.isAvailable,
           !selfUpdateFailed, installPhase == nil, pendingVersion != nil {
            performUpdate()
        }
        if userInitiated {
            // The strip itself carries the version and the action; a note on top
            // of it would just repeat them.
            clearNote()
        }
        Self.writeState(state)
    }

    private func note(_ text: String, transient: Bool = true) {
        noteTask?.cancel()
        statusNote = text
        guard transient else { return }
        noteTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self.statusNote = nil
        }
    }

    // MARK: State
    //
    // UserDefaults, and it stays there: what GitHub last said and when is a
    // cache, not a setting, and a settings file someone edits by hand has no
    // business carrying a timestamp perch rewrites every hour. The one thing
    // here that IS a setting — the automatic-check switch — lives in
    // `settings.json` with the rest (`AppConfigFile.swift`).
    //
    // Perch is the only reader (pounce needs a file instead, because a daemon
    // and a shell script share the state). Under the sandbox this is the
    // container's own defaults, so a `bench try` dev build — which signs under
    // `com.hausfold.perch.dev` — keeps its own, exactly like its own staging
    // directory.

    enum Key {
        static let checkedAt = "update.checkedAt"
        static let latest = "update.latest"
        static let dismissed = "update.dismissed"
    }

    private struct State {
        var checkedAt: TimeInterval?
        var latest: String?
        var dismissed: String?
    }

    private static func readState(defaults: UserDefaults = .standard) -> State {
        State(
            checkedAt: defaults.object(forKey: Key.checkedAt) as? TimeInterval,
            latest: defaults.string(forKey: Key.latest),
            dismissed: defaults.string(forKey: Key.dismissed)
        )
    }

    private static func writeState(_ state: State, defaults: UserDefaults = .standard) {
        put(state.checkedAt, Key.checkedAt, defaults)
        put(state.latest, Key.latest, defaults)
        put(state.dismissed, Key.dismissed, defaults)
    }

    // Typed, so a nil never reaches `set(_: Any?, forKey:)` — an Optional boxed
    // into Any is not a property-list value and would trap at write time.
    private static func put(_ value: TimeInterval?, _ key: String, _ defaults: UserDefaults) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private static func put(_ value: String?, _ key: String, _ defaults: UserDefaults) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
