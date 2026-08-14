import XCTest

@testable import Perch

/// Retention is the one path that can delete a staged copy without anyone
/// asking for it, so the rule it turns on is worth pinning down.
///
/// A staged copy is deleted outright rather than trashed — perch is sandboxed,
/// so its Trash is inside its own container and Finder never shows it — and for
/// a dragged-in promise, a link, typed text, or anything a paired iPhone sent,
/// the shelf copy is the only copy. Hence: off unless asked for, and no way to
/// fall into an expiry by accident.
@MainActor
final class ShelfRetentionTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "PerchRetention-\(UUID().uuidString)"
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    // MARK: - The cutoff rule

    func testRetentionOffYieldsNoCutoff() {
        XCTAssertNil(
            ShelfStore.expiryCutoff(retentionDays: 0),
            "0 days means never — there must be no cutoff to compare against."
        )
    }

    /// Defensive: a negative can only arrive from a hand-edited defaults plist,
    /// and the safe reading of "minus three days" is "don't".
    func testNegativeRetentionYieldsNoCutoff() {
        XCTAssertNil(ShelfStore.expiryCutoff(retentionDays: -3))
    }

    func testPositiveRetentionCutsAtThatManyDaysBack() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let cutoff = try XCTUnwrap(ShelfStore.expiryCutoff(retentionDays: 7, now: now))
        let expected = Calendar.current.date(byAdding: .day, value: -7, to: now)
        XCTAssertEqual(cutoff, try XCTUnwrap(expected))
        XCTAssertLessThan(cutoff, now)
    }

    /// The regression this replaces: the old code fell back to `.distantPast` on
    /// failed date arithmetic. `.distantPast` is older than every item, so the
    /// filter kept nothing — a date-math failure would have emptied the shelf.
    /// Failing to `nil` fails the other way.
    func testCutoffIsNeverOlderThanEveryItem() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let cutoff = try XCTUnwrap(ShelfStore.expiryCutoff(retentionDays: 30, now: now))
        XCTAssertGreaterThan(cutoff, .distantPast)
    }

    // MARK: - The default

    func testRetentionIsOffOnAFreshInstall() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        XCTAssertEqual(
            settings.retentionDays, 0,
            "Nothing may be deleted on a timer until someone turns the timer on."
        )
        XCTAssertNil(ShelfStore.expiryCutoff(retentionDays: settings.retentionDays))
    }

    /// A stored 0 has to survive the read. The old init clamped with `max(1,)`,
    /// which made "never" unrepresentable — anyone who chose it got a one-day
    /// expiry instead, which is the most destructive setting available.
    func testStoredNeverIsNotClampedUpToOneDay() throws {
        let defaults = try makeDefaults()
        defaults.set(0, forKey: "retentionDays")
        XCTAssertEqual(AppSettings(defaults: defaults).retentionDays, 0)
    }

    func testAnExplicitRetentionIsKept() throws {
        let defaults = try makeDefaults()
        defaults.set(14, forKey: "retentionDays")
        XCTAssertEqual(AppSettings(defaults: defaults).retentionDays, 14)
    }
}
