import SwiftUI

/// Keeps indeterminate work visible without spinning when Reduce Motion is on.
struct MotionAwareProgressView: View {
    let accessibilityLabel: String
    var isCompact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Image(systemName: "hourglass")
                    .symbolVariant(.none)
            } else {
                ProgressView()
                    .controlSize(isCompact ? .mini : .regular)
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }
}
