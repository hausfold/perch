import CoreGraphics
import Foundation

/// Where each item's drag image sits, relative to the others, for the duration
/// of a drag-out.
///
/// This geometry is not decoration — it is what the destination places the
/// dropped files by. `NSDraggingItem.setDraggingFrame` sets the item's
/// `NSDraggingFormationNone` position, and that is the layout AppKit hands a
/// destination to animate to and that Finder's icon view lays the arriving
/// files out from (`NSDraggingInfo.animatesToDestination`, `NSDragging.h`).
///
/// Perch used to give every item past the fifth the *same* frame — a deliberate
/// five-deep cascade that looked like a small pile. Fifty folders therefore
/// arrived asking for one position fifty times over, and Finder resolved the
/// pile-up the only way it can: by cascading them itself, into the top-left to
/// bottom-right diagonal of field-test #9.
///
/// So the frames are a real grid now, and the *look* of the drag is handed to
/// `NSDraggingFormationStack` instead, which is the formation's job — "drag
/// images are laid out overlapping diagonally", applied to the visuals without
/// touching the positions a destination reads. It is what Finder itself does
/// dragging a multi-selection: a neat stack under the pointer, a grid on
/// arrival.
enum DragLayout {
    /// Side of one drag image, and of one grid cell's icon.
    static let iconSide: CGFloat = 48

    /// Distance between neighbouring cells. Comfortably wider than a Finder
    /// icon-view cell at its largest, because two frames that overlap in the
    /// destination's grid are two frames it has to de-overlap — which is the
    /// bug this replaces.
    static let cellSide: CGFloat = 128

    /// Widest the grid gets before it starts a new row. Fifty items become
    /// 8 × 7 rather than a single 50-wide line, so the arrangement Finder
    /// receives is a block whatever the count.
    static let maximumColumns = 8

    /// Frames for `count` items, laid out left-to-right and top-to-bottom
    /// around `center` in a flipped-y (AppKit view) coordinate space.
    ///
    /// A single item sits exactly on the centre, which is what a one-tile drag
    /// has always done and what makes the drag image track the pointer.
    static func frames(count: Int, center: CGPoint) -> [CGRect] {
        guard count > 1 else {
            return count == 1
                ? [CGRect(
                    x: center.x - iconSide / 2,
                    y: center.y - iconSide / 2,
                    width: iconSide,
                    height: iconSide
                )]
                : []
        }

        let columns = min(count, maximumColumns)
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        // Centre the whole block on the tile, so the pointer stays in the
        // middle of the pile rather than at its top-left corner.
        let originX = center.x - (CGFloat(columns - 1) * cellSide) / 2 - iconSide / 2
        let originY = center.y - (CGFloat(rows - 1) * cellSide) / 2 - iconSide / 2

        return (0..<count).map { index in
            CGRect(
                x: originX + CGFloat(index % columns) * cellSide,
                y: originY + CGFloat(index / columns) * cellSide,
                width: iconSide,
                height: iconSide
            )
        }
    }
}
