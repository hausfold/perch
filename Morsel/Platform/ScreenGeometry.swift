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
            collapsedWidth = max(150, (screen.cameraHousingWidth ?? 0) + 20)
            collapsedHeight = max(34, screen.safeAreaTop + 8)
        } else {
            collapsedWidth = 154
            collapsedHeight = 28
        }

        let expandedWidth = min(540, max(280, screen.frame.width - 48))
        let expandedHeight = min(286, max(220, screen.frame.height * 0.28))
        collapsedFrame = CGRect(
            x: centerX - collapsedWidth / 2,
            y: screen.frame.maxY - collapsedHeight,
            width: collapsedWidth,
            height: collapsedHeight
        )
        expandedFrame = CGRect(
            x: centerX - expandedWidth / 2,
            y: screen.frame.maxY - expandedHeight,
            width: expandedWidth,
            height: expandedHeight
        )
    }
}

extension NSScreen {
    var morselIdentifier: String {
        if let number = deviceDescription[.init("NSScreenNumber")] as? NSNumber {
            return number.stringValue
        }
        return "\(frame.origin.x):\(frame.origin.y):\(frame.width)x\(frame.height)"
    }
}
