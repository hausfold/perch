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
        let onPointerScreen = NSScreen.screens
            .first { $0.frame.contains(point) }
            .flatMap { panels[$0.perchIdentifier] }
        // The pointer may be on a display with no panel of its own — with the
        // setting off that is every display but one. Fall back to the primary
        // display's shelf rather than doing nothing; never to an arbitrary
        // dictionary entry, whose order is undefined.
        let fallback = ShelfWindowSystem.primaryScreen()
            .flatMap { panels[$0.perchIdentifier] }
        (onPointerScreen ?? fallback)?.expand()
    }

    /// The display the single-panel case belongs on.
    ///
    /// Not `NSScreen.main`: that is the *key window's* screen, so with focus on
    /// a secondary display the one shelf would be built for that display
    /// instead. `NSScreen.screens[0]` is the zero-origin display — the one
    /// carrying the menu bar, and the one with the notch on a laptop.
    private static func primaryScreen() -> NSScreen? {
        NSScreen.screens.first ?? NSScreen.main
    }

    private func rebuildPanels() {
        panels.values.forEach { $0.close() }
        panels.removeAll()

        let screens: [NSScreen]
        if settings.showOnAllDisplays {
            screens = NSScreen.screens
        } else if let primary = ShelfWindowSystem.primaryScreen() {
            screens = [primary]
        } else {
            screens = []
        }

        for screen in screens {
            // Mirrored displays can report the same NSScreenNumber. Assigning
            // into the dictionary would drop the earlier controller *without
            // closing it*, leaving an orphaned panel on the notch that nothing
            // can collapse and that eats every click on the one below it.
            guard panels[screen.perchIdentifier] == nil else { continue }
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
