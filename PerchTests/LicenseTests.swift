import CryptoKit
import XCTest
@testable import Perch

/// The licensing rules, pinned the way `UpdateCheckTests` pins the nudge:
/// everything here is pure, so the suite never needs a real license, a purchase,
/// or — critically — the production signing key. Each test mints its own
/// throwaway Ed25519 keypair, which is the whole reason `LicenseVerifier` takes
/// its key by injection instead of reading the baked-in constant.
final class LicenseTests: XCTestCase {

    // MARK: - Fixtures

    private let signingKey = Curve25519.Signing.PrivateKey()

    private var verifier: LicenseVerifier {
        LicenseVerifier(publicKey: signingKey.publicKey.rawRepresentation)
    }

    /// Build a license and sign it the way the Worker will.
    private func signed(
        product: String = "perch",
        email: String = "buyer@example.com",
        purchased: String = "2026-08-03",
        seats: Int = 3
    ) throws -> Data {
        let unsigned = License(
            product: product,
            email: email,
            purchased: purchased,
            seats: seats,
            sig: ""
        )
        let signature = try signingKey.signature(for: unsigned.canonicalPayload)
        let license = License(
            product: product,
            email: email,
            purchased: purchased,
            seats: seats,
            sig: signature.base64EncodedString()
        )
        return try JSONEncoder().encode(license)
    }

    // MARK: - The canonical payload
    //
    // The signer (a Cloudflare Worker) and the verifier (this app) never share
    // code, so the ONE thing that must never drift is the exact byte string
    // being signed. Pin it literally: a change here silently invalidates every
    // license already in a customer's inbox.

    func testCanonicalPayloadIsTheExactBytesBothEndsAgreeOn() {
        let license = License(
            product: "perch",
            email: "buyer@example.com",
            purchased: "2026-08-03",
            seats: 3,
            sig: "ignored"
        )
        XCTAssertEqual(
            String(decoding: license.canonicalPayload, as: UTF8.self),
            """
            product=perch
            email=buyer@example.com
            purchased=2026-08-03
            seats=3
            """
        )
    }

    /// The signature is deliberately NOT part of what it signs.
    func testCanonicalPayloadIgnoresTheSignatureField() {
        let base = License(product: "perch", email: "a@b.c", purchased: "2026-01-01", seats: 1, sig: "")
        let signed = License(product: "perch", email: "a@b.c", purchased: "2026-01-01", seats: 1, sig: "AAAA")
        XCTAssertEqual(base.canonicalPayload, signed.canonicalPayload)
    }

    // MARK: - Verification

    func testAGenuineLicenseVerifies() throws {
        let license = try verifier.license(from: try signed())
        XCTAssertEqual(license.email, "buyer@example.com")
        XCTAssertEqual(license.seats, 3)
    }

    /// Every field is covered by the signature — editing any of them in a text
    /// editor has to fail, including the one someone would actually edit.
    func testEditingAnyFieldBreaksTheSignature() throws {
        let genuine = try signed()
        for (find, replace) in [
            ("buyer@example.com", "someone.else@example.com"),
            ("2026-08-03", "2036-08-03"),   // the field a forger would move
            ("\"seats\":3", "\"seats\":99"),
        ] {
            var json = String(decoding: genuine, as: UTF8.self)
            json = json.replacingOccurrences(of: find, with: replace)
            // The seats edit only bites if the substitution actually happened —
            // JSONEncoder spacing would otherwise make this a silent no-op.
            XCTAssertNotEqual(json, String(decoding: genuine, as: UTF8.self), find)
            XCTAssertThrowsError(try verifier.license(from: Data(json.utf8))) { error in
                XCTAssertEqual(error as? LicenseError, .badSignature, find)
            }
        }
    }

    /// A license signed by anyone else is a forgery, however well-formed.
    func testAnotherKeysSignatureIsRejected() throws {
        let stranger = LicenseVerifier(
            publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        )
        XCTAssertThrowsError(try stranger.license(from: try signed())) { error in
            XCTAssertEqual(error as? LicenseError, .badSignature)
        }
    }

    /// The format is meant to be shared with a second paid app, so the product
    /// scope is what stops that app's license from unlocking perch. Checked
    /// before the signature, so the message names the actual problem.
    func testAnotherProductsLicenseDoesNotUnlockPerch() throws {
        let other = try signed(product: "someotherapp")
        XCTAssertThrowsError(try verifier.license(from: other)) { error in
            XCTAssertEqual(error as? LicenseError, .wrongProduct("someotherapp"))
        }
    }

    func testGarbageIsMalformed() {
        for junk in ["", "not json", "{}", "{\"product\":\"perch\"}"] {
            XCTAssertThrowsError(try verifier.license(from: Data(junk.utf8)), junk) { error in
                XCTAssertEqual(error as? LicenseError, .malformed, junk)
            }
        }
    }

    /// A build with no key baked in must reject everything rather than accept
    /// everything — the safe direction to fail.
    func testABuildWithNoPublicKeyRejectsEverything() throws {
        let keyless = LicenseVerifier(publicKey: Data())
        XCTAssertThrowsError(try keyless.license(from: try signed())) { error in
            XCTAssertEqual(error as? LicenseError, .noPublicKey)
        }
    }

    // MARK: - Coverage
    //
    // CalVer IS the entitlement: a purchase covers builds dated on or before
    // purchase + 1 year, and keeps working on them forever.

    private func license(purchased: String) -> License {
        License(product: "perch", email: "a@b.c", purchased: purchased, seats: 1, sig: "")
    }

    func testAPurchaseCoversAYearOfBuilds() {
        let bought = license(purchased: "2026-08-03")
        XCTAssertTrue(bought.covers(buildVersion: "2026.08.03"))   // the day itself
        XCTAssertTrue(bought.covers(buildVersion: "2026.12.25"))
        XCTAssertTrue(bought.covers(buildVersion: "2027.08.03"))   // the last day
        XCTAssertFalse(bought.covers(buildVersion: "2027.08.04"))  // one day past
        XCTAssertFalse(bought.covers(buildVersion: "2029.01.01"))
    }

    /// A build predating the purchase is covered too: buying today must not
    /// leave last month's release locked.
    func testOlderBuildsAreCovered() {
        XCTAssertTrue(license(purchased: "2026-08-03").covers(buildVersion: "2025.01.01"))
    }

    /// The same-day `-N` suffix is a repeat of one day, not a later one.
    func testSameDayRepeatsDoNotFallOutOfCoverage() {
        let bought = license(purchased: "2026-08-03")
        XCTAssertTrue(bought.covers(buildVersion: "2027.08.03-4"))
        XCTAssertFalse(bought.covers(buildVersion: "2027.08.04-1"))
    }

    /// An Xcode build's placeholder and a `bench try` branch build have no date
    /// to compare, so a license holder feel-testing a branch stays licensed
    /// rather than being told their purchase lapsed.
    func testUndatedBuildsStayCovered() {
        let bought = license(purchased: "2026-08-03")
        for version in ["dev", "0.1.0", "2026.08.03-dev", ""] {
            XCTAssertTrue(bought.covers(buildVersion: version), version)
        }
    }

    /// A malformed purchase date can't cover anything — better than a license
    /// that covers everything because a field failed to parse.
    func testAnUnparseablePurchaseDateCoversNothing() {
        for bad in ["", "not-a-date", "2026-13-01", "26-08-03"] {
            XCTAssertNil(license(purchased: bad).coveredThrough, bad)
            XCTAssertFalse(license(purchased: bad).covers(buildVersion: "2026.08.03"), bad)
        }
    }

    /// Coverage must not depend on where the buyer is standing: both sides are
    /// resolved in UTC, so the boundary falls on the same build everywhere.
    func testCoverageIsTimezoneIndependent() {
        let bought = license(purchased: "2026-08-03")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(
            bought.coveredThrough,
            utc.date(from: DateComponents(year: 2027, month: 8, day: 3))
        )
    }

    // MARK: - The free-tier cap

    /// Pinned against `freeTierCapacity` rather than a literal, so moving the
    /// product knob doesn't need the arithmetic re-derived by hand — the shape
    /// of the rule is what's under test, not the number.
    func testTheFreeShelfFillsToItsCapAndNoFurther() {
        let cap = LicenseStore.freeTierCapacity
        XCTAssertEqual(LicenseStore.admissible(requested: 1, onShelf: 0, capacity: cap), 1)
        XCTAssertEqual(LicenseStore.admissible(requested: cap, onShelf: 0, capacity: cap), cap)
        // The classic case: a full free shelf, one more dropped.
        XCTAssertEqual(LicenseStore.admissible(requested: 1, onShelf: cap, capacity: cap), 0)
        // A partial batch is admitted, not refused wholesale — dropping a pile
        // onto an empty free shelf fills it rather than doing nothing.
        XCTAssertEqual(LicenseStore.admissible(requested: cap + 5, onShelf: 0, capacity: cap), cap)
        XCTAssertEqual(LicenseStore.admissible(requested: cap + 5, onShelf: cap - 1, capacity: cap), 1)
    }

    /// The knob itself: a free tier of zero would be a hard paywall wearing a
    /// free tier's clothes, and the plan says this only ever moves looser.
    func testTheFreeTierIsAWorkingShelfNotAZero() {
        XCTAssertGreaterThanOrEqual(LicenseStore.freeTierCapacity, 1)
    }

    /// A licensed shelf has no ceiling at all.
    func testALicensedShelfIsUncapped() {
        XCTAssertEqual(LicenseStore.admissible(requested: 500, onShelf: 900, capacity: nil), 500)
    }

    /// Never negative: an over-full shelf (the cap was loosened, then tightened,
    /// or a licence lapsed with items already on it) admits nothing rather than
    /// returning a negative that would slice an array backwards.
    func testAnOverFullShelfAdmitsNothingRatherThanGoingNegative() {
        XCTAssertEqual(LicenseStore.admissible(requested: 2, onShelf: 9, capacity: 3), 0)
        XCTAssertEqual(LicenseStore.admissible(requested: 0, onShelf: 0, capacity: 3), 0)
    }

    // MARK: - The kill switch
    //
    // The cap and the ability to honour a license are the same switch. Until
    // Phase 2 bakes the public key in, a capped shelf would be a paywall with
    // no door — everyone already using perch loses the free shelf and has no
    // way to buy it back. These pin that they move together.

    @MainActor
    func testAKeylessBuildHasNoCeiling() {
        let store = LicenseStore(
            defaults: isolatedDefaults(),
            verifier: LicenseVerifier(publicKey: Data()),
            buildVersion: "2026.08.03"
        )
        XCTAssertFalse(store.canSell)
        XCTAssertNil(store.capacity, "A build that can't sell must not cap the shelf")
    }

    @MainActor
    func testAKeyedBuildCapsAnUnlicensedShelf() {
        let store = LicenseStore(
            defaults: isolatedDefaults(),
            verifier: verifier,
            buildVersion: "2026.08.03"
        )
        XCTAssertTrue(store.canSell)
        // A DEBUG build is licensed by default (developing perch shouldn't mean
        // tripping over its own paywall), so the cap only exists once the
        // escape hatch puts this build back on the free tier.
        store.removeLicense()
        #if DEBUG
        XCTAssertNil(store.capacity)
        #else
        XCTAssertEqual(store.capacity, LicenseStore.freeTierCapacity)
        #endif
    }

    /// Each store gets its own defaults so a test never writes into the real
    /// container or reads another test's license.
    private func isolatedDefaults() -> UserDefaults {
        let suite = "com.hausfold.perch.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite) ?? .standard
    }

    // MARK: - Recognising a license on the shelf

    func testALicenseFileIsAKeyNotCargo() {
        XCTAssertTrue(LicenseStore.isLicenseFile(URL(fileURLWithPath: "/tmp/perch.perchlicense")))
        // Case-insensitive: mail clients and Finder both rewrite extensions.
        XCTAssertTrue(LicenseStore.isLicenseFile(URL(fileURLWithPath: "/tmp/Perch.PerchLicense")))
        for path in [
            "/tmp/report.pdf",
            "/tmp/perchlicense",
            "/tmp/a.perchlicense.txt",
            "/tmp/perch.nebelhauslicense",
        ] {
            XCTAssertFalse(LicenseStore.isLicenseFile(URL(fileURLWithPath: path)), path)
        }
    }

    // MARK: - The shipped key

    /// Phase 2 mints the keypair and fills this constant in. Until it does, the
    /// app must be verifiably keyless rather than carrying a plausible-looking
    /// placeholder that would quietly accept nothing forever without anyone
    /// noticing — this test is the reminder, and it flips to the real assertion
    /// (a 32-byte key) the moment the constant lands.
    func testTheProductionKeyIsEitherAbsentOrAValidEd25519Key() {
        let raw = Data(base64Encoded: LicenseVerifier.productionPublicKeyBase64) ?? Data()
        if raw.isEmpty {
            XCTAssertEqual(
                LicenseVerifier.productionPublicKeyBase64, "",
                "Placeholder public key that isn't valid base64 — Phase 2 must set a real 32-byte key."
            )
        } else {
            XCTAssertEqual(raw.count, 32, "Ed25519 public keys are 32 bytes")
            XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: raw))
        }
    }
}
