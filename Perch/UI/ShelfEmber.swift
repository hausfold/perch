import SwiftUI

/// The collapsed shelf's only visible mark: a small sage ember tucked under
/// whatever occupies the top edge of the display — the camera housing on a notch
/// Mac, the menu bar on every other. Nothing is ever painted over the housing or
/// out in the band beside it where status items live; the ember hangs off the
/// chin, reading as a light on the hardware rather than as UI.
///
/// It signals *presence*, never an exact number — a pip per item up to `maxPips`
/// and no further. To know precisely what is staged, open the shelf.
///
/// Three states, all driven from state the shelf already tracks:
///   * at rest    — one pip per staged item
///   * on arrival — the pips flare white-hot and settle back over ~0.6s
///   * armed      — the pips fuse into a landing strip as wide as the housing, so
///                  "you can drop here" only appears while a drag could be in
///                  flight
struct ShelfEmber: View {
    let itemCount: Int
    /// A transfer is still being staged — the ember breathes until it lands.
    let isStaging: Bool
    /// A mouse button is held somewhere on the system; see `ShelfPanelState.isArmed`.
    let isArmed: Bool
    /// Width of the physical camera housing, or 0 on a notchless display, where
    /// the landing strip falls back to its own width.
    let housingWidth: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rice) private var rice

    /// The palette's green — `#abe1a6` under stock nebelung, which is perch's
    /// mark green: deliberately the muted sage of the app icon and not a
    /// saturated green, which at this size and this close to the camera would
    /// read as the system's recording indicator. A latte rice swaps in its own
    /// green, which is darker for the same reason, against a bright desktop.
    private var ember: Color { rice.green }
    private static let pipSize: CGFloat = 5
    /// Past this the row stops growing. Presence is the signal, not the total.
    private static let maxPips = 5
    /// Strip width when there is no housing to match.
    private static let notchlessStripWidth: CGFloat = 132

    /// 0 at rest, 1 at the peak of a new-item flare.
    @State private var flare: CGFloat = 0
    /// Drives the staging breath: toggled once, then left to a repeating animation.
    @State private var breathing = false

    var body: some View {
        ZStack {
            if isArmed {
                landingStrip
            } else {
                pips
            }
        }
        .animation(.snappy(duration: 0.22), value: isArmed)
        .opacity(isStaging && breathing ? 0.42 : 1)
        .animation(breathAnimation, value: breathing)
        .onChange(of: itemCount) { previous, current in
            // Only a landing flares; items leaving the shelf just fade a pip out.
            guard current > previous, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.1)) { flare = 1 }
            withAnimation(.easeOut(duration: 0.6).delay(0.1)) { flare = 0 }
        }
        .onChange(of: isStaging, initial: true) { _, staging in
            breathing = staging && !reduceMotion
        }
        .accessibilityLabel(itemCount == 1 ? "1 item staged" : "\(itemCount) items staged")
    }

    /// A single toggle animated `repeatForever` oscillates for as long as the
    /// value stays put; dropping back to a plain animation lands it on full.
    private var breathAnimation: Animation {
        breathing
            ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
            : .easeOut(duration: 0.25)
    }

    private var pips: some View {
        HStack(spacing: 4) {
            // max(_, 1): the shelf can hold zero items while a transfer is still
            // staging — that state is one breathing pip, not nothing.
            ForEach(0 ..< min(max(itemCount, 1), Self.maxPips), id: \.self) { _ in pip }
        }
        .animation(.snappy(duration: 0.26), value: itemCount)
    }

    private var pip: some View {
        Circle()
            .fill(ember)
            // The flare's hot core, layered over the sage rather than
            // interpolated into it so the resting colour is always exact. It
            // burns towards the palette's brightest neutral, so on a latte it
            // reads as a flash rather than as a hole punched in the pip.
            .overlay { Circle().fill(rice.isLight ? rice.crust : .white).opacity(0.85 * flare) }
            .frame(width: Self.pipSize, height: Self.pipSize)
            .scaleEffect(1 + 0.55 * flare)
            .modifier(EmberGlow(flare: flare, ember: ember))
            .transition(.opacity.combined(with: .scale(scale: 0.4)))
    }

    private var landingStrip: some View {
        Capsule()
            .fill(ember.opacity(0.85))
            .frame(
                width: housingWidth > 0 ? housingWidth : Self.notchlessStripWidth,
                height: 3
            )
            .modifier(EmberGlow(flare: flare, ember: ember))
    }
}

/// Two stacked shadows — a tight core and a wide bloom — so the ember looks lit
/// rather than drawn. Both widen with the flare. Kept as one modifier so the pip
/// and the strip glow identically.
private struct EmberGlow: ViewModifier {
    var flare: CGFloat
    var ember: Color

    func body(content: Content) -> some View {
        content
            .shadow(color: ember.opacity(0.5 + 0.4 * flare), radius: 3 + 5 * flare)
            .shadow(color: ember.opacity(0.2 + 0.3 * flare), radius: 8 + 10 * flare)
    }
}
