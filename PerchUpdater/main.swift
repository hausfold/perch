import AppKit
import Foundation
import os

// MARK: - PerchUpdater
//
// A background app (`LSUIElement`), nested in `Perch.app/Contents/Library/`,
// with NO sandbox — the one process in the family that can put a new build into
// `/Applications`. It has no window, no menu, no user input, and exactly one
// run: read the request perch left in its container, install, relaunch perch,
// exit.
//
// It is a real `NSApplication` rather than a bare tool on purpose: an app
// bundle whose `main` never runs a run loop is launched by LaunchServices
// anyway, but the launch is only reported back to the caller after a 30-second
// timeout and its `NSWorkspace` arguments are dropped (measured 2026-08-26).
// `NSApp` costs one file and makes the launch immediate.
//
// Run by hand for a feel test:
//   .../Perch.app/Contents/Library/PerchUpdater.app/Contents/MacOS/PerchUpdater
// with a request already written — see docs/feel-testing.md.

private let logger = Logger(subsystem: "com.hausfold.perch.updater", category: "Run")

// Not main-actor isolated, and it must not become so: it sleeps waiting for
// perch to exit and blocks on the relaunch callback, and the main run loop has
// to stay free for `NSWorkspace` to deliver that callback at all.
private func run() -> Int32 {
    let installer = Installer()

    guard let target = Installer.enclosingAppBundle() else {
        logger.error("not nested inside an app bundle — nothing this updater is allowed to touch")
        return 1
    }
    guard let appID = Installer.bundleIdentifier(at: target) else {
        logger.error("the enclosing bundle has no identifier")
        return 1
    }

    // The request lives in the app's container. A perch that somehow isn't
    // sandboxed would have written it under the real home instead; try both
    // rather than fail on a shape we don't ship but could build.
    let homes = [
        UpdateHandoff.containerHome(appBundleID: appID),
        UpdateHandoff.realHome,
    ]
    guard let home = homes.first(where: {
        FileManager.default.fileExists(atPath: UpdateHandoff.requestURL(home: $0).path)
    }) else {
        logger.error("no update request to act on")
        return 1
    }

    let requestURL = UpdateHandoff.requestURL(home: home)
    guard let data = try? Data(contentsOf: requestURL),
          let request = try? JSONDecoder().decode(UpdateRequest.self, from: data) else {
        logger.error("the update request is unreadable")
        try? FileManager.default.removeItem(at: requestURL)
        return 1
    }
    // Consumed, whatever happens next: a request left on disk would be replayed
    // by the next launch of this updater.
    try? FileManager.default.removeItem(at: requestURL)

    installer.waitForExit(pid: request.appPID)

    var result = UpdateResult(
        version: request.version,
        succeeded: false,
        message: "",
        finishedAt: Date().timeIntervalSince1970
    )
    do {
        result.message = try installer.install(request: request, target: target)
        result.succeeded = true
    } catch {
        result.message = error.localizedDescription
        logger.error("update failed: \(result.message, privacy: .public)")
    }
    result.finishedAt = Date().timeIntervalSince1970

    // Written before the relaunch so the app finds it on the way up. The
    // updater is outside the sandbox, so writing into perch's container is
    // ordinary file I/O here.
    let resultURL = UpdateHandoff.resultURL(home: home)
    try? FileManager.default.createDirectory(
        at: resultURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    if let encoded = try? JSONEncoder().encode(result) {
        try? encoded.write(to: resultURL, options: .atomic)
    }

    // The staged download is the biggest thing in Caches and it is spent now,
    // succeeded or not.
    try? FileManager.default.removeItem(
        at: UpdateHandoff.downloadDirectory(home: home)
    )

    guard request.relaunch else { return result.succeeded ? 0 : 2 }

    // Relaunch whatever is now at the target path — the new build on success,
    // the untouched old one on failure. A failed update must not also cost the
    // user their shelf.
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.createsNewApplicationInstance = true
    let semaphore = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: target, configuration: configuration) { app, error in
        if let error {
            logger.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
        } else {
            logger.log("relaunched \(app?.processIdentifier ?? -1, privacy: .public)")
        }
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 30)
    return result.succeeded ? 0 : 2
}

private final class UpdaterDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Off the main thread: the install waits on another process and on the
        // filesystem, and the run loop has to stay alive to service the
        // `NSWorkspace` relaunch callback.
        DispatchQueue.global(qos: .userInitiated).async {
            exit(run())
        }
    }
}

let application = NSApplication.shared
private let delegate = UpdaterDelegate()
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
