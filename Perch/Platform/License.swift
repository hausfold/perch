import CryptoKit
import Foundation

// MARK: - License (offline, Ed25519-signed, product-scoped)
//
// Perch is paid, and the gate lives in the binary — never in the distribution.
// Releases stay public and all four install doors (cask, release ZIP, the rice's
// Nix copy, a bare nix store path) stay open; what the app checks is whether a
// signed license file sits in its container.
//
// **Offline, forever.** The README's load-bearing sentence — "the only network
// call it makes is an hourly look at perch's own release tag" — is a contract,
// so licensing gets no network call at all: no activation server, no
// phone-home, no key-activation endpoint. An Ed25519 signature over a canonical
// payload, verified against a public key baked into the app, is the whole
// mechanism. It works on an air-gapped Mac and it can't be revoked out from
// under someone who paid.
//
// **CalVer is the entitlement.** A purchase buys one year of updates and works
// forever on the builds it covers. Rather than bookkeeping version lists, the
// app compares its own `MARKETING_VERSION` date to the purchase date: a build
// dated on or before `purchased + 1 year` is covered. That keeps `bench
// release` untouched, keeps the rule explainable in one sentence, and means an
// old build someone's license covered keeps working forever — coverage is a
// fact about two dates, not a server's opinion.

/// A parsed `.nebelhauslicense` file.
///
/// Deliberately product-scoped so trill reuses the format, the signer, and the
/// mail template untouched — the only thing that differs between the two apps
/// is which `product` string they accept.
struct License: Equatable, Codable {
    /// Which nebelhaus app this license unlocks. Perch accepts `"perch"` and
    /// nothing else, so a trill license pasted into perch fails cleanly rather
    /// than half-working.
    let product: String
    /// Who bought it. Shown in Settings so a license is identifiable at a
    /// glance; never sent anywhere.
    let email: String
    /// Purchase date, `YYYY-MM-DD`. The left edge of the update year.
    let purchased: String
    /// Informational only. Seats are an honour-system number printed in
    /// Settings: an offline license can't count installs, and a licensing
    /// feature that wanted to would need the network call we refuse to add.
    let seats: Int
    /// Base64 Ed25519 signature over `canonicalPayload`.
    let sig: String

    /// The exact bytes the signer signs and the app verifies.
    ///
    /// Not the JSON: canonicalizing JSON (key order, whitespace, unicode
    /// escaping, integer formatting) is a well-known source of signature
    /// mismatches, and we own both ends, so the payload is a fixed-order
    /// newline-joined `key=value` list with no trailing newline. The signing
    /// script in the Worker builds the same string.
    ///
    ///     product=perch
    ///     email=buyer@example.com
    ///     purchased=2026-08-03
    ///     seats=3
    var canonicalPayload: Data {
        Data(
            """
            product=\(product)
            email=\(email)
            purchased=\(purchased)
            seats=\(seats)
            """.utf8
        )
    }

    /// The file extension the picker filters on and a shelf drop recognises.
    static let fileExtension = "nebelhauslicense"

    /// The one product string this app honours.
    static let expectedProduct = "perch"

    /// How long a purchase keeps covering new builds.
    static let updateYears = 1
}

// MARK: - Failure modes

enum LicenseError: LocalizedError, Equatable {
    /// The bytes aren't a license file at all.
    case malformed
    /// Signed and well-formed, but for a different nebelhaus app.
    case wrongProduct(String)
    /// The signature doesn't verify, or the base64 is junk.
    case badSignature
    /// The app was built without a licensing public key. Cannot happen in a
    /// release; kept as a real case so a mis-built binary says so instead of
    /// silently rejecting every valid license as a forgery.
    case noPublicKey

    var errorDescription: String? {
        switch self {
        case .malformed:
            return "That doesn't look like a Perch license file."
        case let .wrongProduct(product):
            return "That's a \(product) license, not a Perch one."
        case .badSignature:
            return "That license file couldn't be verified. Re-download it from your purchase email."
        case .noPublicKey:
            return "This build of Perch can't verify licenses. Please report it."
        }
    }
}

// MARK: - Verification

/// Pure Ed25519 verification, with the key injected.
///
/// The app builds one of these from the baked-in production key; the test suite
/// builds one per test from a keypair it generates on the spot, so the suite
/// never needs — and can never leak — the real signing key.
struct LicenseVerifier {
    /// Raw 32-byte Ed25519 public key.
    let publicKey: Data

    /// Base64 of the 32-byte Ed25519 public key whose private half signs every
    /// license perch will ever honour.
    ///
    /// **Empty until Phase 2 mints the keypair** (private half → a Cloudflare
    /// Worker secret plus one offline backup; this constant → the public half).
    /// An empty key means no license can verify, so a build that shipped
    /// without it runs everyone on the free tier rather than letting a forgery
    /// through — the safe direction to fail.
    static let productionPublicKeyBase64 = ""

    static var production: LicenseVerifier {
        LicenseVerifier(publicKey: Data(base64Encoded: productionPublicKeyBase64) ?? Data())
    }

    /// Parse and verify raw file bytes.
    func license(from data: Data) throws -> License {
        guard let license = try? JSONDecoder().decode(License.self, from: data) else {
            throw LicenseError.malformed
        }
        guard license.product == License.expectedProduct else {
            throw LicenseError.wrongProduct(license.product)
        }
        guard !publicKey.isEmpty, let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            throw LicenseError.noPublicKey
        }
        guard let signature = Data(base64Encoded: license.sig),
              key.isValidSignature(signature, for: license.canonicalPayload)
        else {
            throw LicenseError.badSignature
        }
        return license
    }
}

// MARK: - Coverage
//
// Two dates and one comparison. `purchased` is the license's own `YYYY-MM-DD`;
// the build's date is the `YYYY.MM.DD` prefix of its CalVer `MARKETING_VERSION`
// (the same-day `-N` suffix never changes the day, so it is ignored here).

extension License {
    /// Midnight UTC of the purchase date, or nil if the field isn't a date.
    ///
    /// UTC on both sides on purpose: coverage must not depend on which timezone
    /// the buyer's Mac is in, or a license bought at the boundary would cover a
    /// different set of builds in Auckland than in Los Angeles.
    var purchasedDate: Date? { Self.day(fromISO: purchased) }

    /// The last day of builds this license covers — `purchased` + the update
    /// year. Shown in Settings and in the update nudge.
    var coveredThrough: Date? {
        guard let purchasedDate else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(byAdding: .year, value: Self.updateYears, to: purchasedDate)
    }

    /// Does this license cover a build stamped `version` (CalVer, no leading v)?
    ///
    /// A version that isn't CalVer — an Xcode build's placeholder
    /// `MARKETING_VERSION`, or a `bench try` branch build's `-dev` suffix — has
    /// no date to compare, so it is covered: a license holder feel-testing a
    /// branch should not be told their license lapsed.
    func covers(buildVersion version: String) -> Bool {
        guard let coveredThrough else { return false }
        guard let built = Self.day(fromCalVer: version) else { return true }
        return built <= coveredThrough
    }

    /// `YYYY-MM-DD` → midnight UTC.
    static func day(fromISO string: String) -> Date? {
        day(year: string, separator: "-")
    }

    /// `YYYY.MM.DD` or `YYYY.MM.DD-N` → midnight UTC, or nil if not CalVer.
    static func day(fromCalVer version: String) -> Date? {
        let head = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
        return day(year: head, separator: ".")
    }

    private static func day(year string: String, separator: Character) -> Date? {
        let parts = string.split(separator: separator)
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              parts[0].count == 4, (1...12).contains(m), (1...31).contains(d)
        else {
            return nil
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: DateComponents(year: y, month: m, day: d))
    }
}

// MARK: - State

/// What the app is entitled to right now.
enum LicenseState: Equatable {
    /// No license, or one that failed to verify: the free tier.
    case free
    /// A verified license that covers this build.
    case licensed(License)
    /// A verified license whose update year ended before this build was cut.
    /// The purchase is not void — it still covers every build up to
    /// `coveredThrough`, and downgrading to one of those restores it. This
    /// build runs the free tier and says which builds the license does cover.
    case uncovered(License)

    var license: License? {
        switch self {
        case .free: return nil
        case let .licensed(license), let .uncovered(license): return license
        }
    }

    var isLicensed: Bool {
        if case .licensed = self { return true }
        return false
    }
}
