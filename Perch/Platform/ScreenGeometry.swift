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
    let hasCameraHousing: Bool

    init(screen: ScreenDescriptor) {
        hasCameraHousing = screen.hasCameraHousing
        let centerX = screen.frame.midX
        let collapsedWidth: CGFloat
        let collapsedHeight: CGFloat

        if screen.hasCameraHousing {
            // Wide, shallow catch band centered under the notch. Width covers
            // off-center drag paths (the empty middle of the menu bar, clear of
            // the app menus at far-left and status items at far-right). Height
            // stays close to the menu-bar band so it catches a dragged file a
            // touch below the very top edge — before macOS's edge-drag gesture
            // (Mission Control / Spaces) fires — without eating clicks on app
            // content further down.
            collapsedWidth = max(360, min(screen.frame.width * 0.42, 640))
            collapsedHeight = screen.safeAreaTop + 34
        } else {
            collapsedWidth = max(300, min(screen.frame.width * 0.32, 460))
            collapsedHeight = 44
        }

        // A comfortable reading width for the tile strip — deliberately a touch
        // narrower than the catch band (roughly one tile unit trimmed off the
        // old 660) so a dense shelf fills its rows more uniformly. `usable` (a
        // 24pt inset per side) is a hard ceiling, so the panel stays fully
        // on-screen even on an unusually narrow display.
        let usable = screen.frame.width - 48
        let expandedWidth = min(usable, max(360, min(540, usable)))
        // Size the panel to a single tile row plus the header and padding, not a
        // tall fixed rectangle — otherwise the item strip's flexible height
        // leaves dead space below the tiles. The camera housing reserves extra
        // top padding (see ShelfPanelView), so a notch display needs more.
        let expandedHeight: CGFloat = hasCameraHousing ? 244 : 220
        collapsedFrame = CGRect(
            x: centerX - collapsedWidth / 2,
            y: screen.frame.maxY - collapsedHeight,
            width: collapsedWidth,
            height: collapsedHeight
        )
        // Bleed a few points above the screen's top edge so NSGlassEffectView's
        // bright edge rim lands off-screen — leaving a clean, borderless top.
        let topBleed: CGFloat = 4
        expandedFrame = CGRect(
            x: centerX - expandedWidth / 2,
            y: screen.frame.maxY - expandedHeight,
            width: expandedWidth,
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
