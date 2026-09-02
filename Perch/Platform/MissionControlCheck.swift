import AppKit
import Foundation
import os

// MARK: - Mission Control check (the one system setting perch needs)
//
// System Settings ▸ Desktop & Dock ▸ "Drag windows to top of screen to enter
// Mission Control" is ON by default, and the Dock arms that top-edge trigger for
// the whole duration of ANY drag session — files included, despite the key's
// name. The band it watches is exactly where the notch catch zone lives, so on a
// stock Mac the FIRST drag someone aims at the shelf is taken into Mission
// Control before perch ever sees a `draggingEntered:`. The app looks broken by
// the only gesture it has.
//
// Perch cannot defend against this from inside the app: the Dock's edge monitor
// runs above every window level, so no panel can shadow it, and intercepting the
// drag would need a `CGEventTap` — an Accessibility grant perch deliberately
// refuses to ask for. A system toggle is the honest fix. What perch CAN do is
// notice the trigger is armed and say so, in the two places it already says
// things: a strip along the bottom of the open shelf, and a row in the menu bar
// menu. Same surfaces as `UpdateCheck`, same reason — perch asks the system for
// no notification permission, so every nudge waits until you look.
//
// Reading another app's preference domain needs an entitlement. Measured
// 2026-08-26 on macOS 26.6: under the sandbox, `UserDefaults(suiteName:)`,
// `CFPreferencesCopyAppValue` and a direct read of
// ~/Library/Preferences/com.apple.dock.plist ALL come back nil/false without
// one; with `temporary-exception.shared-preference.read-only` naming
// `com.apple.dock`, the two preference reads return the real value and the file
// read stays denied. That is the narrowest handle on this fact that exists — one
// domain, read-only, no filesystem widening — and it is why the entitlement is
// in Perch.entitlements.
//
// The haus desktop turns the Dock trigger off whenever `haus.shelf.enable` is
// on, so a haus install reads `false` here and never sees any of this.

@MainActor
final class MissionControlCheck: ObservableObject {
    static let shared = MissionControlCheck()

    /// Is the Dock's top-edge trigger armed — i.e. will it eat drags aimed at
    /// the notch?
    @Published private(set) var isArmed = false
    /// Waved off from the shelf strip, persisted. Unlike `UpdateCheck`'s
    /// per-version dismissal there is nothing to re-ask about, so this is
    /// forever — which is exactly why the MENU row ignores it. A menu costs
    /// nothing while closed, so the answer stays findable after the strip is
    /// gone for good.
    @Published private(set) var isDismissed: Bool

    /// The Dock's own domain and key. The key's name says "windows"; the
    /// behaviour covers file drags too, which is the whole problem.
    nonisolated static let dockDomain = "com.apple.dock"
    nonisolated static let dockKey = "enterMissionControlByTopWindowDrag"

    /// Desktop & Dock, where the toggle lives. `com.apple.Desktop-Settings.extension`
    /// is the pane's real bundle id on macOS 26 (System Settings is ExtensionKit
    /// panes now, not prefPanes) — read off
    /// /System/Library/ExtensionKit/Extensions/DesktopSettings.appex.
    nonisolated static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
    )!

    private static let dismissedKey = "MissionControlHintDismissed"
    /// What the Dock posts when its preferences change, so flipping the toggle
    /// clears the strip while it is on screen rather than at the next launch.
    private static let dockPrefChanged = "com.apple.dock.prefchanged"

    private let logger = Logger(subsystem: "com.hausfold.perch", category: "MissionControl")
    private var didStart = false

    private init(defaults: UserDefaults = .standard) {
        isDismissed = defaults.bool(forKey: Self.dismissedKey)
    }

    // MARK: Pure rules

    /// Absent means ARMED: macOS ships this on, and a Mac that has never had the
    /// key written is the stock Mac this whole check exists for. A denied read
    /// is indistinguishable from an absent key and lands here too — erring
    /// toward showing a dismissible hint rather than silently letting the one
    /// gesture perch has fail.
    nonisolated static func isArmed(dockPreference: Bool?) -> Bool {
        dockPreference ?? true
    }

    /// The strip's condition. The menu row uses `isArmed` alone.
    var showsHint: Bool { isArmed && !isDismissed }

    // MARK: Lifecycle

    /// Called once from `AppRuntime.start()`.
    func start() {
        guard !didStart else { return }
        didStart = true
        refresh()

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(Self.dockPrefChanged),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { MissionControlCheck.shared.refresh() }
        }
        // The lid being shut is the gap a notification alone can't close: perch
        // is an accessory app that stays running for weeks.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { MissionControlCheck.shared.refresh() }
        }
    }

    /// Re-read the Dock's answer. No network, but not free either: the
    /// synchronize below is a synchronous `cfprefsd` round-trip that reaches the
    /// on-disk store, which is exactly why it can see a toggle another process
    /// just wrote. Called on every shelf expand as well as from the two
    /// observers — once per expand, and it is what makes "I just turned it off"
    /// clear the strip that is telling you to.
    func refresh() {
        let armed = Self.isArmed(dockPreference: Self.readDockPreference())
        guard armed != isArmed else { return }
        isArmed = armed
        logger.info("Mission Control top-edge drag trigger armed: \(armed, privacy: .public)")
    }

    func openSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }

    func dismiss(defaults: UserDefaults = .standard) {
        isDismissed = true
        defaults.set(true, forKey: Self.dismissedKey)
    }

    // MARK: Reading the Dock

    /// `CFPreferencesAppSynchronize` first: without it this process keeps the
    /// value it cached at first read, and a toggle flipped in System Settings
    /// would not land until relaunch. It is a `cfprefsd` round-trip, not a
    /// memory read — the cost of being right about another process's writes.
    private static func readDockPreference() -> Bool? {
        CFPreferencesAppSynchronize(dockDomain as CFString)
        let value = CFPreferencesCopyAppValue(dockKey as CFString, dockDomain as CFString)
        return (value as? NSNumber)?.boolValue
    }
}
