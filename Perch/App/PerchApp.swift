import AppKit
import SwiftUI

@main
struct PerchApp: App {
    @NSApplicationDelegateAdaptor(PerchAppDelegate.self) private var appDelegate
    @StateObject private var runtime = AppRuntime.shared
    @StateObject private var update = UpdateCheck.shared

    var body: some Scene {
        MenuBarExtra {
            Button("Open Shelf") {
                runtime.windowSystem.toggleShelfOnPointerScreen()
            }
            .keyboardShortcut("o")

            if !runtime.store.items.isEmpty {
                Divider()
                Text("\(runtime.store.items.count) staged item\(runtime.store.items.count == 1 ? "" : "s")")
                Button("Clear Shelf", role: .destructive) {
                    runtime.store.clear()
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
            Button("Pair a Device…") {
                MobilePairingWindowController.shared.present(receiver: runtime.mobile)
            }

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
}

@MainActor
final class PerchAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppRuntime.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppRuntime.shared.windowSystem.stop()
    }
}
