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
// `Perch.app/Contents/Library/PerchUpdater.app`, signed with the same team,
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
    func install(request: UpdateRequest, target: URL) throws -> String {
        let payload = URL(fileURLWithPath: request.payloadPath).standardizedFileURL

        // 1 · the target is ours, and it is the bundle we live in
        guard request.targetPath.isEmpty || URL(fileURLWithPath: request.targetPath).standardizedFileURL == target else {
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
        let installed = Self.shortVersion(at: target) ?? "dev"
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
        try? xattr.run()
        xattr.waitUntilExit()
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
            try? fm.moveItem(at: aside, to: target)
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
