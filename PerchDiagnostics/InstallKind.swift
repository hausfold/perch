import Foundation

// MARK: - InstallKind
//
// Which of the four doors this copy of Perch came through. It lives here, in a
// folder both the app and the `perch` tool compile, because BOTH have to answer
// it and neither can ask the other: the app quotes the cohort into the bug
// report form, and `perch doctor` has to name the right update command on a Mac
// where the app is not running at all. A second copy of these rules in the CLI
// would be a second answer to "how do I update this", which is exactly the
// question a cohort exists to settle once.
//
// The detection itself is pure — `detect(bundlePath:home:…)`. Each side reads
// the receipts the way its own sandboxing allows and passes them in; the app's
// half is `detectLive()` in `Perch/Platform/UpdateCheck.swift`, the tool's is
// `Doctor.installKind(…)`.

/// How THIS install takes an update — decides the hint, the button, and the
/// command the button copies.
enum InstallKind: String, Codable, Equatable, CaseIterable {
    /// Homebrew cask — `brew` owns the version.
    case homebrew
    /// Dragged out of the release ZIP — nothing upstream owns this copy, so
    /// perch installs it itself (`SelfUpdate.swift`).
    case direct
    /// The haus desktop's activation copy — `haus update`.
    ///
    /// The case is spelled `rice` to match this codebase's older internal
    /// vocabulary (`RicePalette`, `RiceFiles`); the RAW value is `haus` because
    /// `perch doctor --json` publishes it, and that is the first machine-readable
    /// place the cohort is quoted. "Say haus or desktop, never rice" applies to
    /// anything outside this repo reads.
    case rice = "haus"
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
    /// its own bytes: a haus or cask install swapped from under its package
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
    // Path prefixes alone can't tell the cohorts apart: haus copies the
    // bundle to `/Applications/Perch.app` (modules/shelf, postActivation) and a
    // cask's `app` stanza MOVES it to the same path — so haus, cask, and
    // drag-install are byte-identical locations. Out-of-band receipts break the
    // tie:
    //
    //   haus   /Library/Application Support/haus/perch.installed-from —
    //          written by the activation script with the store path it copied.
    //   cask   <brew prefix>/Caskroom/perch — brew's own staging directory,
    //          which survives the app being moved to /Applications.
    //
    // Both of those live outside perch's container, so under the sandbox the
    // reads may simply be denied — `fileExists` then answers false for a receipt
    // that is really there. That is why there is a third, always-readable
    // signal: `~/.config/perch/config.json`, haus's theme drop, which the
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

        // haus reinstalls on every activation, so its marker outranks a
        // leftover cask receipt from a machine that has been both.
        if hasRiceMarker, bundlePath == "/Applications/Perch.app" { return .rice }
        if hasCaskReceipt { return .homebrew }
        // Sandbox fallback: neither receipt was readable. A haus theme drop at
        // haus's own install path means haus put this here.
        if hasRiceThemeDrop, bundlePath == "/Applications/Perch.app" { return .rice }
        return .direct
    }
}
