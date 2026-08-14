import AppKit
import Foundation

@MainActor
final class AppRuntime: ObservableObject {
    static let shared = AppRuntime()

    let settings: AppSettings
    let theme: ShelfTheme
    let store: ShelfStore
    let windowSystem: ShelfWindowSystem
    let mobile: MobileReceiver
    let finderActions: FinderActionReceiver
    /// Held here, not handed to `NSApp` and forgotten: the services provider is
    /// the receiver for every later Finder invocation, and nothing else retains it.
    let services: ShelfServicesProvider

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
        mobile = MobileReceiver(store: store, settings: settings)
        finderActions = FinderActionReceiver(store: store)
        services = ShelfServicesProvider(store: store)
    }

    func start() {
        NSApp.setActivationPolicy(.accessory)
        store.restore()
        services.register()
        finderActions.start()
        windowSystem.start()
        UpdateCheck.shared.start()
        mobile.start()
    }

    func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func stop() {
        finderActions.stop()
        windowSystem.stop()
    }
}
