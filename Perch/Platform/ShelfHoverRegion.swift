import CoreGraphics

/// The passive-hover band inside a shelf panel: a sub-rect of the collapsed
/// catch zone, centered horizontally and anchored to the top edge (the notch).
///
/// Pure geometry, deliberately free of AppKit. `mouseEntered(with:)` fires for
/// **every** tracking area whose owner is the hosting view — including the
/// full-bounds one `NSHostingView` installs for SwiftUI's own `.onHover` — so
/// the trigger cannot trust *which* area fired and has to hit-test the pointer
/// itself. That hit test is this type, and it runs without a window server.
enum ShelfHoverRegion {
    /// - Parameters:
    ///   - bounds: the hosting view's bounds (the full, wide catch zone).
    ///   - width: band width; `nil` or `>= bounds.width` means the full width.
    ///   - height: band depth from the top edge; `nil` or `>= bounds.height`
    ///     means the full height.
    ///   - isFlipped: the view's `isFlipped` — decides which edge is "top".
    static func rect(
        in bounds: CGRect,
        width: CGFloat?,
        height: CGFloat?,
        isFlipped: Bool
    ) -> CGRect {
        var rect = bounds
        if let width, width < rect.width {
            rect = rect.insetBy(dx: (rect.width - width) / 2, dy: 0)
        }
        if let height, height < rect.height {
            // Anchored to the top edge of the panel (the notch), not centered:
            // the slack in the collapsed frame is all below the housing.
            rect = CGRect(
                x: rect.minX,
                y: isFlipped ? rect.minY : rect.maxY - height,
                width: rect.width,
                height: height
            )
        }
        return rect
    }
}
