import AppKit

/// perch's one Finder door: the "Add to Perch Shelf" entry declared in
/// `Perch/Config/Info.plist`, which macOS draws under *Services*.
///
/// There used to be a second — a `PerchFinderAction` Action Extension — kept on
/// the belief that it drew in a different submenu. It didn't, and it didn't
/// work: measured on macOS 26 (field test 2026-08-23), both doors landed under
/// Services with the same title, and clicking the extension's row shelved
/// nothing. It was removed, and this is what remains.
///
/// Being delivered to the *running* app is the reason this half is the simple
/// one: it reuses `ShelfDropHandler` verbatim, so there is no mailbox, no
/// second staging path, and nothing new to keep in sync. (`PerchFinderBridge`'s
/// mailbox stays — the `perch` CLI is still a sender.)
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
        if let failure = handle(pasteboard) {
            error.pointee = failure as NSString
        }
    }

    /// The selector's body, minus the out-parameter. Split out so tests can
    /// reach it without hand-forging an `NSString **`, which is exactly the
    /// kind of bridging a test should not be proving anything about.
    ///
    /// Returns the message to show, or `nil` on success.
    func handle(_ pasteboard: NSPasteboard) -> String? {
        dropHandler.accept(pasteboard)
            ? nil
            : "Perch could not read what Finder handed over."
    }
}
