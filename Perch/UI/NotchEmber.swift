import SwiftUI

/// The notch-display counterpart to the notchless pill: a tiny sage ember tucked
/// against the bottom edge of the camera housing, so a staged shelf is legible in
/// peripheral vision without drawing any chrome. Nothing is ever painted over the
/// housing itself — the ember hangs off its chin, reading as a light on the
/// hardware rather than as UI.
///
/// Three states, all driven from state the shelf already tracks:
///   * at rest    — one pip per staged item (past `maxPips`, one pip + a count)
///   * on arrival — the pips flare white-hot and settle back over ~0.6s
///   * armed      — the pips fuse into a landing strip exactly as wide as the
///                  housing, so "you can drop here" only appears while a drag
///                  could actually be in flight
struct NotchEmber: View {
    let itemCount: Int
    /// A transfer is still being staged — the ember breathes until it lands.
    let isStaging: Bool
    /// A mouse button is held somewhere on the system; see `ShelfPanelState.isArmed`.
    let isArmed: Bool
    /// Width of the physical camera housing. The landing strip spans it exactly.
    let housingWidth: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Perch's mark green (`#abe1a6`) — deliberately the muted sage of the app
    /// icon and not a saturated green, which at this size and this close to the
    /// camera would read as the system's recording indicator.
    private static let ember = Color(red: 0.671, green: 0.882, blue: 0.651)
    private static let pipSize: CGFloat = 5
    private static let maxPips = 4

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

    @ViewBuilder private var pips: some View {
        HStack(spacing: 4) {
            if itemCount > Self.maxPips {
                pip
                Text("\(itemCount)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Self.ember.opacity(0.92))
                    .contentTransition(.numericText())
                    .shadow(color: Self.ember.opacity(0.45), radius: 3)
            } else {
                // max(_, 1): the shelf can have zero items while a transfer is
                // still staging — that state is one breathing pip, not nothing.
                ForEach(0 ..< max(itemCount, 1), id: \.self) { _ in pip }
            }
        }
    }

    private var pip: some View {
        Circle()
            .fill(Self.ember)
            // The flare's white-hot core, layered over the sage rather than
            // interpolated into it so the resting colour is always exact.
            .overlay { Circle().fill(.white).opacity(0.85 * flare) }
            .frame(width: Self.pipSize, height: Self.pipSize)
            .scaleEffect(1 + 0.55 * flare)
            .modifier(EmberGlow(flare: flare))
    }

    private var landingStrip: some View {
        Capsule()
            .fill(Self.ember.opacity(0.85))
            // Fall back to a readable stub if the housing width is unknown.
            .frame(width: housingWidth > 0 ? housingWidth : 120, height: 3)
            .modifier(EmberGlow(flare: flare))
    }
}

/// Two stacked shadows — a tight core and a wide bloom — so the ember looks lit
/// rather than drawn. Both widen with the flare. Kept as one modifier so the pip
/// and the strip glow identically.
private struct EmberGlow: ViewModifier {
    var flare: CGFloat

    private static let ember = Color(red: 0.671, green: 0.882, blue: 0.651)

    func body(content: Content) -> some View {
        content
            .shadow(color: Self.ember.opacity(0.5 + 0.4 * flare), radius: 3 + 5 * flare)
            .shadow(color: Self.ember.opacity(0.2 + 0.3 * flare), radius: 8 + 10 * flare)
    }
}
