import AppKit

/// The top-level "Add to Perch Shelf" in the Finder context menu.
///
/// This is the classic-Services half of the pair declared in
/// `Perch/Config/Info.plist`; `PerchFinderAction` is the modern app-extension
/// half that lives in the Quick Actions submenu. They differ only in where
/// macOS draws them and who does the copying — a Service is delivered to the
/// running app, so it reuses `ShelfDropHandler` verbatim and there is no
/// mailbox, no second staging path, and nothing new to keep in sync.
///
/// Finder hands over a pasteboard, never a mandate: the source files are read
/// and copied, exactly as a drag onto the shelf reads and copies them.
@MainActor
final class ShelfServicesProvider: NSObject {
    private let dropHandler: ShelfDropHandler

    init(store: ShelfStore) {
        dropHandler = ShelfDropHandler(store: store)
    }

    /// Registers the provider and re-scans this bundle's `NSServices`.
    ///
    /// `NSUpdateDynamicServices()` is what makes a freshly installed build's
    /// menu item appear without a logout — the Services database otherwise
    /// picks it up on its own schedule, which is to say eventually.
    func register() {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    /// `NSMessage` in the Info.plist entry above, so the selector macOS looks
    /// for is `addToShelf:userData:error:`.
    ///
    /// Errors are reported through the `error` out-parameter rather than
    /// thrown: the Services machinery predates Swift, and the string it takes
    /// is what the user sees.
    @objc func addToShelf(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard dropHandler.accept(pasteboard) else {
            error.pointee = "Perch could not read what Finder handed over."
            return
        }
    }
}
