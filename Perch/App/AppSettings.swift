import Foundation
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let showOnAllDisplays = "showOnAllDisplays"
        static let retentionDays = "retentionDays"
        static let mobileEnabled = "mobileEnabled"
    }

    private let defaults: UserDefaults

    @Published var showOnAllDisplays: Bool {
        didSet { defaults.set(showOnAllDisplays, forKey: Key.showOnAllDisplays) }
    }

    /// How many days an untouched item survives on the shelf — or **0, never**,
    /// which is the default.
    ///
    /// Off by default deliberately. Expiry runs `StagingRepository.prune` →
    /// `FileManager.removeItem`: a permanent delete, not a trip to the Trash,
    /// and there is nowhere recoverable to send it instead — perch is
    /// sandboxed, so its Trash is inside its own container where Finder will
    /// never show it. For drag-promised content, typed text and links, and
    /// anything a paired iPhone sent, **the shelf copy is the only copy**. A
    /// timer that quietly deletes that is the one way perch can lose your work
    /// without ever asking, so it is something you switch on, not something you
    /// have to notice and switch off.
    @Published var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Key.retentionDays) }
    }

    /// Whether this Mac listens for its paired iPhones at all. Off tears the
    /// listener down; pairing stays remembered for when it comes back on.
    @Published var mobileEnabled: Bool {
        didSet { defaults.set(mobileEnabled, forKey: Key.mobileEnabled) }
    }

    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showOnAllDisplays: true,
            Key.retentionDays: 0,
            Key.mobileEnabled: true,
        ])
        showOnAllDisplays = defaults.bool(forKey: Key.showOnAllDisplays)
        // `max(0,)`, not `max(1,)` — the old floor made "never" unrepresentable,
        // so a stored 0 silently became a one-day expiry.
        retentionDays = max(0, defaults.integer(forKey: Key.retentionDays))
        mobileEnabled = defaults.bool(forKey: Key.mobileEnabled)
        refreshLaunchAtLogin()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    private func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
