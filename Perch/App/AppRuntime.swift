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
    let watchedFolders: WatchedFolderStore
    let folderWatch: FolderWatchCenter
    /// `NSApp.servicesProvider` is a strong property, so this is not the only
    /// thing keeping the provider alive — it is held here because every other
    /// long-lived collaborator is, and a provider reachable only through
    /// `NSApp` is one nobody thinks to look for.
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
        watchedFolders = WatchedFolderStore()
        folderWatch = FolderWatchCenter(shelf: store, folders: watchedFolders)
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
        folderWatch.start()
    }

    func stop() {
        folderWatch.stop()
        finderActions.stop()
        windowSystem.stop()
    }
}
