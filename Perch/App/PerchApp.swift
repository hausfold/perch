import AppKit
import AppIntents
import SwiftUI

@main
struct PerchApp: App {
    @NSApplicationDelegateAdaptor(PerchAppDelegate.self) private var appDelegate
    // Both @StateObject, whose initializer takes an autoclosure — declaring the
    // menu does not itself reach into the singletons. The paired-device rows
    // need to observe the receiver as well, and `@ObservedObject … =
    // AppRuntime.shared.mobile` here would be a plain stored-property
    // initializer: eager, evaluated with the struct. They observe it from their
    // own small view instead — see `PairedDevicesSection`.
    @StateObject private var runtime = AppRuntime.shared
    @StateObject private var update = UpdateCheck.shared

    init() {
        PerchShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        MenuBarExtra {
            Button("Open Shelf") {
                runtime.windowSystem.toggleShelfOnPointerScreen()
            }
            .keyboardShortcut("o")

            if !runtime.store.items.isEmpty {
                Divider()
                Text("\(runtime.store.items.count) staged item\(runtime.store.items.count == 1 ? "" : "s")")
                // The second door to the same destructive operation, and it
                // has to ask too — a confirm on one of two doors is not a
                // confirm. `role: .destructive` only tints the row.
                //
                // An NSAlert here rather than the panel's in-place arming: a
                // menu closes the moment you click, so there is no armed state
                // left on screen to click a second time. The notch panel's
                // objection to a modal — a transient parent that hides itself
                // out from under the sheet — doesn't apply to an app-modal
                // alert raised from the menu bar.
                Button("Clear Shelf…", role: .destructive) {
                    confirmClearFromMenu()
                }
            }

            Divider()
            // The shelf's update strip is only visible while the shelf is open,
            // so the menu carries the same nudge for anyone who never opens it.
            // Both entries open the shelf too: that is where the answer to a
            // check — and the confirmation that a command was copied — lands.
            if let pending = update.pendingVersion {
                Button("Perch \(pending) is available…") {
                    update.performUpdate()
                    runtime.windowSystem.toggleShelfOnPointerScreen()
                }
            }
            Button("Check for Updates…") {
                update.checkForUpdates(userInitiated: true)
                runtime.windowSystem.toggleShelfOnPointerScreen()
            }

            Divider()
            PairedDevicesSection(mobile: runtime.mobile)

            Divider()
            SettingsLink()
            Button("Quit Perch") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Label("Perch", systemImage: runtime.store.items.isEmpty ? "tray" : "tray.full.fill")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(settings: runtime.settings, mobile: runtime.mobile)
        }
    }

    /// Clearing from the menu asks first, and says what it costs.
    ///
    /// A staged copy is deleted outright — it does not go to the Trash, and
    /// there is nowhere recoverable to send it instead, because perch is
    /// sandboxed and its Trash sits inside its own container. For a dragged-in
    /// promise, a link, typed text, or anything a paired iPhone sent, this is
    /// the only copy there is. So the count goes in the message: "clear 9
    /// items" is a different decision from "clear 1".
    ///
    /// `activate()` first — a menu-bar app is not necessarily frontmost, and an
    /// alert raised behind another app's window is a beachball with no visible
    /// cause.
    private func confirmClearFromMenu() {
        let count = runtime.store.items.count
        guard count > 0 else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear \(count) item\(count == 1 ? "" : "s") from the shelf?"
        alert.informativeText = """
            Perch deletes its staged copies. They do not go to the Trash, and \
            for a dragged-in promise, a link or typed text there is no other copy.
            """
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        // NSAlert makes the first button the default, which would put Return on
        // the destructive one. Move the default to Cancel and give it Escape as
        // well, so both reflexes — hit Return, hit Escape — are the safe answer
        // and clearing takes a deliberate click.
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runtime.store.clear()
    }
}

@MainActor
/// The menu's pairing rows, in their own view so the receiver is observed
/// without the menu's *declaration* reaching into `AppRuntime.shared` — see the
/// note on `PerchApp`'s stored properties.
///
/// It reflects the pairing state rather than offering the same door twice:
/// paired devices are listed (disabled rows), and the action reads accordingly.
private struct PairedDevicesSection: View {
    @ObservedObject var mobile: MobileReceiver

    var body: some View {
        ForEach(mobile.pairedDevices) { device in
            Text("\(device.name) — paired")
        }
        Button(mobile.pairedDevices.isEmpty ? "Pair a Device…" : "Pair Another Device…") {
            MobilePairingWindowController.shared.present(receiver: mobile)
        }
    }
}

final class PerchAppDelegate: NSObject, NSApplicationDelegate {
    /// One perch owns the notch. A second copy is not a second app — it is a
    /// second set of panels at `.statusBar` level covering the first, pixel for
    /// pixel, on every display. They look like one shelf and behave like two:
    /// whichever panel happens to be on top swallows every click and catches
    /// every drop, so the tiles you can see (drawn by the panel underneath, or
    /// showing through the glass) have ✕ and pin badges that do nothing at all,
    /// while the shelf that *did* answer is invisible behind it. Nothing about
    /// that is diagnosable from the front — it just reads as a broken button.
    ///
    /// LaunchServices already refuses to open the same bundle twice, so this
    /// only catches the ways a second copy really does get started: running the
    /// binary directly (a dev build, an agent testing a branch) while an
    /// installed perch is live. The incumbent keeps the notch and this copy
    /// leaves before it has a shelf — nothing is created here, and the panels
    /// are built by `AppRuntime.start()`, which this return path never reaches.
    ///
    /// `PERCH_ALLOW_MULTIPLE=1` opts out, for deliberately comparing two builds
    /// side by side; so does a test run, which never gets a shelf at all (see
    /// `isRunningTests`).
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests,
              ProcessInfo.processInfo.environment["PERCH_ALLOW_MULTIPLE"] != "1",
              let identifier = Bundle.main.bundleIdentifier
        else {
            return
        }
        guard Self.otherRunningPerch(identifier) != nil else { return }
        // A quitting app leaves LaunchServices asynchronously, so "quit perch,
        // then run your build" is a race the first query loses: the incumbent
        // still lists as running and not terminated. One short re-check settles
        // it, and only ever delays the copy that is about to stand down anyway.
        Thread.sleep(forTimeInterval: 0.4)
        guard let incumbent = Self.otherRunningPerch(identifier) else { return }
        // exit() rather than NSApp.terminate(): terminating mid-launch runs the
        // rest of the delegate against a half-built app, and there is nothing to
        // tear down — this copy never started a runtime.
        FileHandle.standardError.write(
            Data("perch is already running (pid \(incumbent.processIdentifier)); leaving the notch to it\n".utf8)
        )
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        AppRuntime.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        AppRuntime.shared.stop()
    }

    /// Another live copy of this bundle, if there is one.
    private static func otherRunningPerch(_ identifier: String) -> NSRunningApplication? {
        let mine = NSRunningApplication.current.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .first { $0.processIdentifier != mine && !$0.isTerminated }
    }

    /// `xcodebuild test` hosts the suite *inside this app*, so a test run is a
    /// real perch launch: without this it starts the whole runtime — notch
    /// panels on every display for the length of the run, hovering open over
    /// the shelf someone is actually using, and a `restore()`/`prune()` against
    /// the machine's live staging repository from a test process. The suite
    /// builds its own stores against temporary directories and wants none of
    /// it, so a test host stays a bare process with no shelf.
    private static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundlePath"] != nil
    }
}
