import AppKit
import AppIntents
import SwiftUI

@main
struct PerchApp: App {
    @NSApplicationDelegateAdaptor(PerchAppDelegate.self) private var appDelegate
    @StateObject private var runtime = AppRuntime.shared
    @StateObject private var update = UpdateCheck.shared
    // Observed directly so the menu re-renders when a device pairs/revokes.
    @ObservedObject private var mobile = AppRuntime.shared.mobile

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
            // The menu reflects the pairing state instead of offering the
            // same door twice: paired devices are listed (disabled rows),
            // and the action reads accordingly.
            ForEach(mobile.pairedDevices) { device in
                Text("\(device.name) — paired")
            }
            Button(mobile.pairedDevices.isEmpty ? "Pair a Device…" : "Pair Another Device…") {
                MobilePairingWindowController.shared.present(receiver: runtime.mobile)
            }

            Divider()
            SettingsMenuItem()
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

/// The menu's way into Settings.
///
/// `SettingsLink` would do it in one line, but it gives no hook to run
/// anything first — and Perch is an accessory app, so the window it opens
/// lands *behind* whatever has focus. Same reason
/// `MobilePairingWindowController.present` activates. So the item drives
/// `openSettings()` itself, activates around it, and orders the window front
/// on the next runloop turn, once SwiftUI has actually made it.
private struct SettingsMenuItem: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
            DispatchQueue.main.async {
                raiseSettingsWindow()
                // A second turn: on a cold open SwiftUI can still be building
                // the window when the first one runs.
                DispatchQueue.main.async { raiseSettingsWindow() }
            }
        }
        .keyboardShortcut(",")
    }

    /// SwiftUI names the Settings window `com_apple_SwiftUI_Settings_window`;
    /// the title is the fallback for the day that identifier changes.
    private func raiseSettingsWindow() {
        let window = NSApp.windows.first { window in
            window.identifier?.rawValue.contains("Settings") == true
                || window.title == SettingsView.windowTitle
        }
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

@MainActor
final class PerchAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppRuntime.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppRuntime.shared.stop()
    }
}
