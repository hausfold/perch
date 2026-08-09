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
// forced by **the app sandbox**:
//
//   apply    a nudge outside the sandbox can go further than naming the step —
//            swap its own bundle for the release ZIP's, or shell out to `brew
//            upgrade`, for the two cohorts that own their bytes. Perch cannot:
//            `ENABLE_APP_SANDBOX = YES`, every child
//            process inherits that sandbox, and /Applications is outside the
//            container — a self-swap would be denied, and a `brew` spawned from
//            here would fail in ways nothing could report. So EVERY cohort here
//            gets an instruction: a command copied to the pasteboard, or the
//            release page. Nothing in this file writes outside the container.
//   surface  the obvious surface is a UNUserNotificationCenter banner. Perch
//            asks the system for no permissions it can avoid (see the Mission
//            Control note in the rice's modules/perch) and notifications are one
//            of them, so the only surfaces are passive: a strip at the bottom of
//            the expanded shelf, and a row in the menu bar menu. Neither
//            interrupts anything; both wait until you look.
//
// Network: one unauthenticated GitHub API call per hour, carrying nothing but an
// IP and a user-agent, off by a Settings toggle. Never runs in DEBUG builds.
// This is the only reason `com.apple.security.network.client` is in the
// entitlements — perch reaches for exactly one host, and only to read a tag.

// MARK: - InstallKind

/// How THIS install takes an update — decides the hint, the button, and the
/// command the button copies.
enum InstallKind: String, Codable, Equatable, CaseIterable {
    /// Homebrew cask — `brew` owns the version.
    case homebrew
    /// Dragged out of the release ZIP — the user replaces the bundle in Finder.
    case direct
    /// The nebelhaus rice's activation copy — `haus update`.
    case rice
    /// A bare Nix store path (`nix run`, someone else's flake) — flake update.
    case nix
    case unknown

    /// The strip's subtitle: what to DO, in this install's own vocabulary.
    var actionHint: String {
        switch self {
        case .homebrew: return "Run brew upgrade --cask perch, then reopen Perch"
        case .direct: return "Download the new build and replace Perch in Applications"
        case .rice: return "Run haus update in a terminal to pick it up"
        case .nix: return "Update your perch flake input to pick it up"
        case .unknown: return "Open the release page to download it"
        }
    }

    /// What the strip's action button says.
    var buttonLabel: String {
        switch self {
        case .homebrew, .rice, .nix: return "Copy Command"
        case .direct, .unknown: return "Open Releases"
        }
    }

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

    /// One line for Settings, so the toggle's copy matches what the shelf offers.
    var settingsNote: String {
        switch self {
        case .homebrew: return "Installed with Homebrew — updates come from brew upgrade --cask perch."
        case .direct: return "Installed from the release ZIP — updates are a download and a drag."
        case .rice: return "Installed by the nebelhaus rice — updates come from haus update."
        case .nix: return "Running from the Nix store — updates come from your flake input."
        case .unknown: return "Updates open the GitHub release page."
        }
    }

    // MARK: Detection
    //
    // Path prefixes alone can't tell the cohorts apart: the rice copies the
    // bundle to `/Applications/Perch.app` (modules/perch, postActivation) and a
    // cask's `app` stanza MOVES it to the same path — so rice, cask, and
    // drag-install are byte-identical locations. Out-of-band receipts break the
    // tie:
    //
    //   rice   /Library/Application Support/nebelhaus/perch.installed-from —
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

    /// Where the rice records the store path it installed from.
    static let riceMarkerPath = "/Library/Application Support/nebelhaus/perch.installed-from"

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
        let hasRiceMarker = fileManager.fileExists(atPath: riceMarkerPath)
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
    /// Transient line shown in the strip — a user-initiated check's answer, or
    /// the confirmation that a command was copied. Nil most of the time.
    @Published private(set) var statusNote: String?

    private let logger = Logger(subsystem: "com.hausfold.perch", category: "Update")
    private var fetching = false
    private var didStart = false
    private var timer: Timer?
    private var noteTask: Task<Void, Never>?

    nonisolated static let endpoint = URL(string: "https://api.github.com/repos/hausfold/perch/releases/latest")!
    /// Hourly: the nudge should show up the day a release is cut, not a day late.
    nonisolated static let maxAge: TimeInterval = 3600
    nonisolated static let releasesURL = URL(string: "https://github.com/hausfold/perch/releases/latest")!

    /// Settings toggle (`Updates` section). Defaults on; user-initiated checks
    /// ignore it, because asking is consent.
    static var automaticChecksEnabled: Bool {
        UserDefaults.standard.object(forKey: Key.automatic) as? Bool ?? true
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
        if version == "dev" || version.isEmpty || version.hasSuffix("-dev") { return true }
        return version.range(
            of: "^[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}(-[0-9]+)?$",
            options: .regularExpression
        ) == nil
    }

    /// CalVer ordering. The zero-padded date compares lexicographically
    /// ("2026.07.29" < "2026.07.30"); the same-day `-N` suffix must compare
    /// NUMERICALLY — a string compare would put "-10" before "-2", which is
    /// exactly the silent-never-nudge bug the tests pin.
    nonisolated static func isNewer(_ candidate: String, than running: String) -> Bool {
        guard !isDevVersion(running) else { return false }
        let c = split(candidate), r = split(running)
        return c.date == r.date ? c.repeatN > r.repeatN : c.date > r.date
    }

    private nonisolated static func split(_ version: String) -> (date: String, repeatN: Int) {
        guard let dash = version.firstIndex(of: "-") else { return (version, 0) }
        return (
            String(version[..<dash]),
            Int(version[version.index(after: dash)...]) ?? 0
        )
    }

    // MARK: Lifecycle

    /// Called once from `AppRuntime.start()`. Checks now, then hourly, then on
    /// wake — perch is an accessory app that stays running for weeks, so the lid
    /// being shut is the gap the timer alone can't close.
    func start() {
        guard !didStart else { return }
        didStart = true
        checkForUpdates()
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
    // UserDefaults: perch is the only reader (pounce needs a file instead,
    // because a daemon and a shell script share the state). Under the sandbox
    // this is the container's own defaults, so a `bench try` dev build — which
    // signs under `com.hausfold.perch.dev` — keeps its own, exactly like its
    // own staging directory.

    private enum Key {
        static let checkedAt = "update.checkedAt"
        static let latest = "update.latest"
        static let dismissed = "update.dismissed"
        static let automatic = "automaticUpdateChecks"
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
