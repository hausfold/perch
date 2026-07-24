import Foundation
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let autoRemoveAfterExport = "autoRemoveAfterExport"
        static let showOnAllDisplays = "showOnAllDisplays"
        static let expandOnPointerHover = "expandOnPointerHover"
        static let retentionDays = "retentionDays"
    }

    private let defaults: UserDefaults

    @Published var autoRemoveAfterExport: Bool {
        didSet { defaults.set(autoRemoveAfterExport, forKey: Key.autoRemoveAfterExport) }
    }

    @Published var showOnAllDisplays: Bool {
        didSet { defaults.set(showOnAllDisplays, forKey: Key.showOnAllDisplays) }
    }

    @Published var expandOnPointerHover: Bool {
        didSet { defaults.set(expandOnPointerHover, forKey: Key.expandOnPointerHover) }
    }

    @Published var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Key.retentionDays) }
    }

    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.autoRemoveAfterExport: false,
            Key.showOnAllDisplays: true,
            Key.expandOnPointerHover: true,
            Key.retentionDays: 7,
        ])
        autoRemoveAfterExport = defaults.bool(forKey: Key.autoRemoveAfterExport)
        showOnAllDisplays = defaults.bool(forKey: Key.showOnAllDisplays)
        expandOnPointerHover = defaults.bool(forKey: Key.expandOnPointerHover)
        retentionDays = max(1, defaults.integer(forKey: Key.retentionDays))
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
