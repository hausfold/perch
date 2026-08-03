import AppKit
import Foundation

@MainActor
final class AppRuntime: ObservableObject {
    static let shared = AppRuntime()

    let settings: AppSettings
    let theme: ShelfTheme
    let store: ShelfStore
    let windowSystem: ShelfWindowSystem

    private init() {
        settings = AppSettings()
        theme = ShelfTheme()
        do {
            let repository = try StagingRepository()
            store = ShelfStore(repository: repository, settings: settings)
        } catch {
            let fallback = FileManager.default.temporaryDirectory
                .appending(path: "Perch-\(UUID().uuidString)", directoryHint: .isDirectory)
            let repository = try! StagingRepository(rootURL: fallback)
            store = ShelfStore(repository: repository, settings: settings)
            store.latestError = "Persistent storage was unavailable. This shelf will last until the app quits."
        }
        windowSystem = ShelfWindowSystem(store: store, settings: settings, theme: theme)
    }

    func start() {
        NSApp.setActivationPolicy(.accessory)
        store.restore()
        windowSystem.start()
        UpdateCheck.shared.start()
    }

    func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
