import AppKit
import Foundation
import Security
import os

// MARK: - Installer
//
// The half of the update that perch's own process is not allowed to do.
//
// `Perch.app` is sandboxed, so it can download a release and unzip it inside
// its container and no further: `/Applications` is outside the container and a
// child process it spawns inherits the same sandbox. An app launched through
// LaunchServices does NOT (probed 2026-08-26: a helper launched with
// `NSWorkspace.openApplication` from a sandboxed parent runs with the real home
// and writes to `/Applications`). So this bundle — nested at
// `Perch.app/Contents/Helpers/PerchUpdater.app`, signed with the same team,
// with no sandbox and no entitlements of its own — is the one that swaps the
// bundle and relaunches.
//
// The whole security argument is three refusals:
//
//   1. It replaces ONLY the app bundle it is nested inside. The request names a
//      target, and a target that isn't `../../..` is refused. There is no
//      invocation of this tool that moves an arbitrary file anywhere.
//   2. The payload must satisfy `PerchSigning.payloadRequirement` — Developer
//      ID, our team, notarized, nested code included. A tampered ZIP, a
//      different developer's build, and an unsigned local build all stop here.
//   3. The payload must be a NEWER release of the SAME bundle id. No
//      downgrades, no swapping perch for something else that happens to be
//      ours.
//
// Everything below runs off the main thread; `main.swift` owns the exit.

struct InstallerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct Installer {
    let logger = Logger(subsystem: "com.hausfold.perch.updater", category: "Install")

    /// The app bundle this updater lives inside — the rule is
    /// `UpdateHandoff.enclosingAppBundle`, shared so `PerchTests` can pin it.
    static func enclosingAppBundle(of updater: URL = Bundle.main.bundleURL) -> URL? {
        UpdateHandoff.enclosingAppBundle(ofUpdaterAt: updater)
    }

    static func bundleIdentifier(at bundle: URL) -> String? {
        Bundle(url: bundle)?.bundleIdentifier
    }

    static func shortVersion(at bundle: URL) -> String? {
        Bundle(url: bundle)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    // MARK: The run

    /// Returns the message to leave in `update-result.json`. Throws on anything
    /// that means the installed app was NOT replaced — in which case the caller
    /// still relaunches what is there, so a failed update never costs the user
    /// their shelf.
    func install(request: UpdateRequest, target: URL, home: URL) throws -> String {
        let payload = URL(fileURLWithPath: request.payloadPath).standardizedFileURL

        // 0 · the payload comes from perch's own staging directory, or it does
        // not come at all. Verifying an arbitrary path and then moving it is a
        // TOCTOU with a wide window — the request and the payload both live
        // where any process running as this user can write. Pinning the
        // directory takes "arbitrary path" out of the request's vocabulary:
        // there is no path in it that names a place perch didn't stage.
        guard UpdateHandoff.isStagedPayload(payload, home: home) else {
            throw InstallerError("the download isn't in perch's staging directory")
        }

        // 1 · the target is ours, and it is the bundle we live in
        // Compared as paths, never as URLs: `URL(fileURLWithPath:)` asks the
        // filesystem whether the path is a directory and adds a trailing slash
        // when it is, while `deletingLastPathComponent()` always adds one — so
        // URL equality here answers differently depending on whether the target
        // happens to exist.
        let requested = URL(fileURLWithPath: request.targetPath).standardizedFileURL.path
        guard request.targetPath.isEmpty || requested == target.path else {
            throw InstallerError("the request names a bundle this updater is not part of")
        }
        guard !target.path.hasPrefix("/nix/store/") else {
            throw InstallerError("this copy is a read-only Nix store path — update the flake input instead")
        }
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw InstallerError("no permission to write \(parent.path) — install it by hand, or move Perch somewhere you own")
        }

        // 2 · the payload is a notarized build of ours
        guard FileManager.default.fileExists(atPath: payload.path), payload.pathExtension == "app" else {
            throw InstallerError("the downloaded app went missing before it could be installed")
        }
        try verifySignature(of: payload)

        // 3 · same app, newer version
        guard let payloadID = Self.bundleIdentifier(at: payload) else {
            throw InstallerError("the download has no bundle identifier")
        }
        guard let targetID = Self.bundleIdentifier(at: target), payloadID == targetID else {
            throw InstallerError("the download is a different app (\(payloadID))")
        }
        guard let payloadVersion = Self.shortVersion(at: payload) else {
            throw InstallerError("the download has no version")
        }
        guard payloadVersion == request.version else {
            throw InstallerError("the download is \(payloadVersion), not the \(request.version) that was offered")
        }
        // A target whose version cannot be read is refused outright. Folding it
        // into "dev" would make an unreadable Info.plist accept ANY notarized
        // build of ours, older ones included — a downgrade path opened by
        // accident, from the one branch that exists to let a `bench try` build
        // be updated.
        guard let installed = Self.shortVersion(at: target) else {
            throw InstallerError("can't read the installed version — install it by hand")
        }
        guard CalVer.isNewer(payloadVersion, than: installed) || CalVer.isDev(installed) else {
            throw InstallerError("\(installed) is already installed")
        }

        // 4 · the swap
        stripQuarantine(payload)
        try swap(payload: payload, onto: target)
        logger.log("installed \(payloadVersion, privacy: .public) over \(installed, privacy: .public)")
        return "Updated to Perch \(payloadVersion)"
    }

    // MARK: Verification

    /// Shared with the app side (`UpdateHandoff.swift`) so the check the
    /// download passed and the check the install requires cannot drift apart.
    func verifySignature(of bundle: URL) throws {
        try PerchSigning.verify(bundle: bundle)
    }

    /// Gatekeeper would ask about a quarantined bundle on first launch. We have
    /// just checked the signature and the notarization ourselves, which is the
    /// same question — and an update that reopens with a "downloaded from the
    /// internet" panel is not the one-click this exists to be.
    func stripQuarantine(_ bundle: URL) {
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", bundle.path]
        // `waitUntilExit()` on a Process that never launched raises an
        // Objective-C exception, which Swift cannot catch — the updater would
        // die here, before the swap, before the result file, before the
        // relaunch, and the user would be left with no shelf and no reason.
        do {
            try xattr.run()
            xattr.waitUntilExit()
        } catch {
            logger.error("could not clear quarantine: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: The swap

    func swap(payload: URL, onto target: URL) throws {
        let fm = FileManager.default
        do {
            // Atomic where the volume allows it, and it keeps the old bundle
            // until the new one is in place. Both paths are on the Data volume
            // (the payload comes out of the app's container under ~/Library),
            // which is what `replaceItemAt` needs.
            _ = try fm.replaceItemAt(target, withItemAt: payload, options: [.usingNewMetadataOnly])
            return
        } catch {
            logger.error("replaceItemAt failed: \(error.localizedDescription, privacy: .public) — falling back")
        }
        // Fallback: move the old one aside first so a failure to copy leaves
        // something to put back, rather than a hole where the app was.
        let aside = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).replacing-\(getpid())")
        try? fm.removeItem(at: aside)
        try fm.moveItem(at: target, to: aside)
        do {
            try fm.moveItem(at: payload, to: target)
            try? fm.removeItem(at: aside)
        } catch {
            // Clear whatever half-move is sitting on the target first: without
            // this, a restore that fails because something is already there
            // leaves the user's only copy of perch under a dot-name Finder does
            // not show. If even that fails, the message has to say where it
            // went — this is the one path where the app can end up somewhere
            // the user would never find it.
            try? fm.removeItem(at: target)
            do {
                try fm.moveItem(at: aside, to: target)
            } catch {
                throw InstallerError(
                    "could not put the new build in place, and Perch is now at \(aside.path)"
                )
            }
            throw InstallerError("could not put the new build in place: \(error.localizedDescription)")
        }
    }

    // MARK: Waiting

    /// Wait for the app to be gone. It terminates itself right after launching
    /// us; SIGTERM is the backstop for a shelf stuck on a modal, and after that
    /// we go ahead anyway — replacing a bundle whose image is already mapped is
    /// safe, and the relaunch is what the user is waiting for.
    func waitForExit(pid: Int32, timeout: TimeInterval = 30) {
        guard pid > 0 else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while kill(pid, 0) == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard kill(pid, 0) == 0 else { return }
        logger.log("perch (pid \(pid, privacy: .public)) still up after \(Int(timeout), privacy: .public)s — asking it to quit")
        kill(pid, SIGTERM)
        let hard = Date().addingTimeInterval(5)
        while kill(pid, 0) == 0, Date() < hard {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}
