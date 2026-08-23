import Foundation

/// The shelf header's two-step Clear, as a value rather than a loose `@State`
/// flag and a handful of view modifiers.
///
/// Clear deletes every staged copy, and a staged copy is often the only copy —
/// perch is sandboxed, so a delete cannot go anywhere recoverable. That makes
/// this the most destructive control in the app, and the rules that keep it
/// honest are worth being able to test without a running window:
///
/// - arming is momentary, never a resting state;
/// - arming is against **these items**, not against "the shelf". A shelf that
///   changed under an armed button is a different question, and the answer has
///   to be asked again. Comparing counts would not do — a remove and an add
///   inside the same window leaves the count identical.
///
/// The view keeps the timeout; everything else lives here.
struct ClearConfirmation: Equatable {
    private(set) var isArmed = false

    /// What the shelf held when the button was armed. Empty while disarmed.
    private(set) var armedAgainst: [UUID] = []

    /// One press of the Clear button.
    ///
    /// - Returns: `true` when this press is the confirmation and the caller
    ///   should actually clear. `false` when it merely armed the button.
    mutating func activate(itemIDs: [UUID]) -> Bool {
        if isArmed, armedAgainst == itemIDs {
            disarm()
            return true
        }
        isArmed = true
        armedAgainst = itemIDs
        return false
    }

    mutating func disarm() {
        isArmed = false
        armedAgainst = []
    }

    /// Voids an arming whose shelf has changed underneath it.
    ///
    /// Items arrive while the panel is collapsed — a paired iPhone, the `perch`
    /// tool, a watched folder, the App Intent — so "armed" must not survive into
    /// a shelf the user never looked at.
    mutating func revalidate(against itemIDs: [UUID]) {
        guard isArmed, armedAgainst != itemIDs else { return }
        disarm()
    }
}
