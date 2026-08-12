import AppKit
import SwiftUI

/// Perch has no transparency setting of its own — it only ever mirrors the
/// system's "Reduce Transparency" accessibility setting. When that's on, this
/// swaps the glass/vibrancy material for a solid, non-blurring plate instead.
struct GlassBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeNSView(context: Context) -> GlassBackingView {
        let view = GlassBackingView()
        view.cornerRadius = cornerRadius
        view.reduceTransparency = reduceTransparency
        return view
    }

    func updateNSView(_ nsView: GlassBackingView, context: Context) {
        nsView.cornerRadius = cornerRadius
        nsView.reduceTransparency = reduceTransparency
    }
}

final class GlassBackingView: NSView {
    var cornerRadius: CGFloat = 0 {
        didSet {
            guard cornerRadius != oldValue else { return }
            applyCornerRadius()
        }
    }

    var reduceTransparency = false {
        didSet {
            guard reduceTransparency != oldValue else { return }
            rebuildContent()
        }
    }

    private var contentView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rebuildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // The material can't just be reconfigured in place: a solid plate and
    // NSGlassEffectView/NSVisualEffectView are different view classes, so a
    // live toggle of the system setting rebuilds this view's one child.
    private func rebuildContent() {
        contentView?.removeFromSuperview()

        let content: NSView
        if reduceTransparency {
            let solid = NSView()
            solid.wantsLayer = true
            solid.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            content = solid
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            content = glass
        } else {
            let visualEffect = NSVisualEffectView()
            visualEffect.blendingMode = .behindWindow
            visualEffect.material = .hudWindow
            visualEffect.state = .active
            content = visualEffect
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        contentView = content
        applyCornerRadius()
    }

    private func applyCornerRadius() {
        if #available(macOS 26.0, *), let glass = contentView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        }
    }
}
