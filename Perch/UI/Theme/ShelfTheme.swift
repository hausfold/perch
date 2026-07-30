import AppKit
import SwiftUI

/// The live palette, resolved from the macOS appearance and what the rice wrote,
/// and re-resolved whenever either could have changed.
///
/// Owned by `AppRuntime` and observed by every shelf panel, so a light/dark flip
/// repaints all displays at once. Resolution touches two tiny files, so it is
/// done on the events that matter — launch, the appearance switch, opening the
/// shelf — rather than on a file watcher: a `haus rebuild` lands on the next
/// time the shelf opens, which is the next time anyone can see it.
@MainActor
final class ShelfTheme: ObservableObject {
    @Published private(set) var palette: RicePalette

    private var appearanceObserver: NSKeyValueObservation?

    init(observingSystemAppearance: Bool = true) {
        palette = RiceTheme.palette(
            systemIsLight: RiceTheme.systemIsLight,
            defaults: RiceThemeDefaults.load()
        )
        guard observingSystemAppearance else { return }

        // Two sources for one event, because neither is guaranteed on its own:
        // an `.accessory` app with no key window is a thin case for AppKit's
        // appearance propagation, and the distributed notification is the
        // system-wide announcement. `refresh()` is idempotent and only publishes
        // on an actual change, so hearing it twice costs nothing.
        appearanceObserver = NSApp?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: RiceTheme.systemAppearanceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        appearanceObserver?.invalidate()
    }

    /// Re-read the appearance and the rice's config, and publish only if the
    /// palette actually changed — an unchanged republish would invalidate every
    /// shelf view for nothing, including mid-drag.
    func refresh() {
        let resolved = RiceTheme.palette(
            systemIsLight: RiceTheme.systemIsLight,
            defaults: RiceThemeDefaults.load()
        )
        guard resolved != palette else { return }
        palette = resolved
    }
}

// MARK: - Environment

private struct RicePaletteKey: EnvironmentKey {
    static let defaultValue = RicePalette.nebelung
}

extension EnvironmentValues {
    /// The palette the shelf paints with. Read through the environment rather
    /// than a global so SwiftUI invalidates the views that use it when the
    /// palette changes — including the nested tiles, which observe nothing else.
    var rice: RicePalette {
        get { self[RicePaletteKey.self] }
        set { self[RicePaletteKey.self] = newValue }
    }
}
