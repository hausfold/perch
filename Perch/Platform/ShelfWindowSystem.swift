import AppKit
import Combine

@MainActor
final class ShelfWindowSystem {
    private let store: ShelfStore
    private let settings: AppSettings
    private let theme: ShelfTheme
    private let dropHandler: ShelfDropHandler
    private var panels: [String: ShelfPanelController] = [:]
    /// Panels currently on screen. Exposed for the test that pins down "nothing
    /// reaches the notch before `start()`" — see `ShelfWindowSystemTests`.
    var panelCount: Int { panels.count }
    private var cancellables: Set<AnyCancellable> = []
    private var screenObserver: NSObjectProtocol?
    private var armTimer: Timer?

    init(store: ShelfStore, settings: AppSettings, theme: ShelfTheme) {
        self.store = store
        self.settings = settings
        self.theme = theme
        dropHandler = ShelfDropHandler(store: store)

        // dropFirst: a @Published publisher replays its current value the
        // instant you subscribe, so without it merely *constructing* the window
        // system builds every panel and orders it onto the notch — before
        // `start()`, and before anything that runs at launch can decide this
        // process should not own a shelf at all (a second copy standing down, a
        // test host). Panels are `start()`'s job; this sink is only for the
        // setting changing later.
        settings.$showOnAllDisplays
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.rebuildPanels() }
            .store(in: &cancellables)
    }

    func start() {
        rebuildPanels()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildPanels() }
        }

        // Arm the (invisible) drop catch zones only while a mouse button is
        // held — i.e. a drag might be underway. Polling pressedMouseButtons
        // needs no Accessibility/Input Monitoring permission, preserving the
        // app's no-special-permission guarantee.
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let armed = NSEvent.pressedMouseButtons != 0
                self.panels.values.forEach { $0.setArmed(armed) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        armTimer = timer
    }

    func stop() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        armTimer?.invalidate()
        armTimer = nil
        panels.values.forEach { $0.close() }
        panels.removeAll()
    }

    func openShelfOnPointerScreen() {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let screen, let panel = panels[screen.perchIdentifier] else { return }
        panel.expand()
    }

    private func rebuildPanels() {
        panels.values.forEach { $0.close() }
        panels.removeAll()

        let screens: [NSScreen]
        if settings.showOnAllDisplays {
            screens = NSScreen.screens
        } else if let main = NSScreen.main {
            screens = [main]
        } else {
            screens = []
        }

        for screen in screens {
            let controller = ShelfPanelController(
                screen: screen,
                store: store,
                theme: theme,
                dropHandler: dropHandler
            )
            panels[controller.screenID] = controller
        }
    }
}
