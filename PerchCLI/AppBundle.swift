import AppKit
import Foundation

/// Which `Perch.app` this tool is talking about — asked twice, for two
/// different reasons, and the two answers are allowed to disagree.
///
/// `enclosing` is the bundle these bytes ship inside. `launchServices` is the
/// copy macOS would open for perch's bundle identifier. On a clean Mac they are
/// the same file. On a *development* Mac they routinely are not: every
/// `xcodebuild` registers the app it just built, from wherever `DerivedData`
/// sits, and nothing ever unregisters it (AGENTS.md, measured 2026-08-23 — 40
/// records). That divergence has been misread as a perch bug twice, so
/// `perch doctor` names both rather than picking one and hoping.
enum PerchAppBundle {
    /// The `.app` this tool ships inside, found by walking up from its own
    /// *resolved* executable path rather than by trusting `Bundle.main`.
    ///
    /// Every installer puts the tool on `PATH` as a **symlink** into the
    /// bundle — `nix/package.nix` here, the cask's `binary` stanza, haus's
    /// shelf room — because it is signed and notarized as part of the app and
    /// a copy outside it would be nested code torn out of that seal. Invoked
    /// through such a link, `Bundle.main` is the *link's* directory: no
    /// Info.plist, no `.app` extension. That made `perch --version` print
    /// `unknown` on every install that isn't the raw in-bundle path, and left
    /// the launch fallback with nothing to open.
    static var enclosing: Bundle? {
        guard let executable = executableURL else { return nil }
        // …/Perch.app/Contents/MacOS/perch-cli → …/Perch.app
        let app =
            executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard app.pathExtension == "app" else { return nil }
        return Bundle(url: app)
    }

    /// This binary, with every symlink on the way to it resolved.
    static var executableURL: URL? {
        Bundle.main.executableURL?.resolvingSymlinksInPath()
    }

    /// The copy Launch Services would open for perch's bundle identifier — the
    /// one holding this account's permissions, which is why it is preferred.
    static var launchServices: URL? {
        NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: FinderActionProtocol.appBundleIdentifier
        )
    }

    /// Who to launch: whatever Launch Services considers the installed Perch,
    /// falling back to the bundle this tool is embedded in — which is how a dev
    /// build (its own bundle identifier, unknown to Launch Services) still
    /// finds itself.
    static var launchTarget: URL? { launchServices ?? enclosing?.bundleURL }

    static var version: String {
        enclosing?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
