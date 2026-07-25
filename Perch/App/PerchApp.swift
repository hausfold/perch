import AppKit
import SwiftUI

@main
struct PerchApp: App {
    @NSApplicationDelegateAdaptor(PerchAppDelegate.self) private var appDelegate
    @StateObject private var runtime = AppRuntime.shared

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
            SettingsView(settings: runtime.settings)
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
