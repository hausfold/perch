import AppKit

struct ScreenDescriptor: Equatable, Sendable {
    let frame: CGRect
    let visibleFrame: CGRect
    let safeAreaTop: CGFloat
    let auxiliaryTopLeftArea: CGRect?
    let auxiliaryTopRightArea: CGRect?

    init(
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
    }

    init(screen: NSScreen) {
        self.init(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }

    var hasCameraHousing: Bool {
        safeAreaTop > 0 && auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil
    }

    var cameraHousingWidth: CGFloat? {
        guard hasCameraHousing,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea
        else {
            return nil
        }
        return max(0, right.minX - left.maxX)
    }
}

struct ShelfGeometry: Equatable, Sendable {
    let collapsedFrame: CGRect
    let expandedFrame: CGRect
    // The visible glass shelf is drawn trimmed-and-centered to this width inside
    // the (wider) expanded window. The window itself keeps the full catch-zone
    // width so expand/collapse only ever changes height — growing straight down
    // from the notch. A window that also shrank horizontally would retract its
    // edge past a pointer/drag sitting in the side band, firing a spurious
    // exit → collapse → re-enter jitter, and the sideways motion read as jank.
    let expandedContentWidth: CGFloat
    let hasCameraHousing: Bool
    // Width of the hover-to-expand band, centered inside collapsedFrame. Kept
    // close to the true notch/camera-housing width (or a modest fixed band on
    // a notchless display) rather than matching the wide drag-catch band
    // above — a hover merely passing through the side of that wide band
    // should not pop the shelf open once it has items to reveal.
    let hoverTriggerWidth: CGFloat
    // Depth of whatever occupies the top edge: the camera housing where there is
    // one, otherwise the menu bar. The collapsed ember hangs just under it on
    // either kind of display — never over the housing, and never out in the band
    // beside or behind it where status items live. An auto-hidden menu bar
    // measures 0, which lands the ember on the screen edge, as it should.
    let topEdgeDepth: CGFloat

    init(screen: ScreenDescriptor) {
        hasCameraHousing = screen.hasCameraHousing
        topEdgeDepth = screen.hasCameraHousing
            ? screen.safeAreaTop
            : max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let centerX = screen.frame.midX
        let collapsedWidth: CGFloat
        let collapsedHeight: CGFloat

        if screen.hasCameraHousing {
            // Wide, shallow catch band centered under the notch. Width covers
            // off-center drag paths (the empty middle of the menu bar, clear of
            // the app menus at far-left and status items at far-right). Height
            // stays close to the menu-bar band so it catches a dragged file a
            // touch below the very top edge, without eating clicks on app
            // content further down. Sizing alone cannot dodge the Dock's
            // top-edge Mission Control trigger — that monitor runs above every
            // window level, so it wins wherever the panel ends. Disabling it is
            // a system setting; see docs/reference.md.
            collapsedWidth = max(360, min(screen.frame.width * 0.42, 640))
            collapsedHeight = screen.safeAreaTop + 34
        } else {
            collapsedWidth = max(300, min(screen.frame.width * 0.32, 460))
            collapsedHeight = 44
        }

        if let housingWidth = screen.cameraHousingWidth {
            // A little grace either side of the true housing edge so the
            // trigger isn't pixel-perfect, without approaching the catch band.
            hoverTriggerWidth = min(collapsedWidth, housingWidth + 48)
        } else {
            hoverTriggerWidth = min(collapsedWidth, 160)
        }

        // A comfortable reading width for the tile strip — deliberately a touch
        // narrower than the catch band (roughly one tile unit trimmed off the
        // old 660) so a dense shelf fills its rows more uniformly. `usable` (a
        // 24pt inset per side) is a hard ceiling, so the panel stays fully
        // on-screen even on an unusually narrow display. This sizes the *visible*
        // glass, not the window: the window matches the catch-zone width (below)
        // and the glass is centered within it.
        let usable = screen.frame.width - 48
        let contentWidth = min(usable, max(360, min(540, usable)))
        // Never wider than the catch band — the glass is trimmed *within* the
        // window, so on a narrow display where the catch band is the smaller of
        // the two, the content follows it down.
        expandedContentWidth = min(contentWidth, collapsedWidth)
        // Size the panel to a single tile row plus the header and padding, not a
        // tall fixed rectangle — otherwise the item strip's flexible height
        // leaves dead space below the tiles. The camera housing reserves extra
        // top padding (see ShelfPanelView), so a notch display needs more.
        // The 96pt previews plus their corner badges need enough vertical room
        // to remain fully inside the panel's clipping boundary. Notch displays
        // still reserve the extra 24pt above the content for the housing.
        let expandedHeight: CGFloat = hasCameraHousing ? 280 : 256
        collapsedFrame = CGRect(
            x: centerX - collapsedWidth / 2,
            y: screen.frame.maxY - collapsedHeight,
            width: collapsedWidth,
            height: collapsedHeight
        )
        // Bleed a few points above the screen's top edge so NSGlassEffectView's
        // bright edge rim lands off-screen — leaving a clean, borderless top.
        // The window keeps the collapsed catch width so expand only grows the
        // panel downward (never sideways); the visible glass is trimmed to
        // expandedContentWidth inside it.
        let topBleed: CGFloat = 4
        expandedFrame = CGRect(
            x: centerX - collapsedWidth / 2,
            y: screen.frame.maxY - expandedHeight,
            width: collapsedWidth,
            height: expandedHeight + topBleed
        )
    }
}

extension NSScreen {
    var perchIdentifier: String {
        if let number = deviceDescription[.init("NSScreenNumber")] as? NSNumber {
            return number.stringValue
        }
        return "\(frame.origin.x):\(frame.origin.y):\(frame.width)x\(frame.height)"
    }
}
