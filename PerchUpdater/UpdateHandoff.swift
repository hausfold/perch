import Foundation
import Security

// MARK: - The app ⇄ updater handoff
//
// Compiled into BOTH sides on purpose: `Perch` (sandboxed, writes the request)
// and `PerchUpdater` (not sandboxed, reads it and does the swap). One file, so
// the two halves cannot drift on a key name or a path.
//
// The handoff is a FILE, not an argument list: `NSWorkspace.OpenConfiguration`'s
// `arguments` reach a freshly launched app only when LaunchServices agrees to
// pass them, and a helper that never became a real `NSApplication` gets none at
// all (measured 2026-08-26, on the probe that established this whole approach).
// A file in the app's own container is readable by both sides, survives the
// launch, and is the only thing the updater trusts about *what* to install —
// never about *what to replace*: that is always the bundle the updater is
// nested inside, whatever the request says.

/// Our Developer ID team. Hardcoded like the App Group is, and for the same
/// reason: a value the updater derives from its own signature could be derived
/// from a forged one too.
enum PerchSigning {
    static let teamID = "88M28542LQ"

    /// What a payload must satisfy before it is allowed near `/Applications`.
    /// `notarized` is part of the requirement language (verified with
    /// `codesign -R` against a shipped release, 2026-08-26) — it is what makes
    /// a stolen-cert build fail this check even before revocation lands.
    ///
    /// **Only the updater can evaluate this**, and that is measured, not
    /// assumed: from inside the app's container the same call on the same bytes
    /// answers errSecCSReqFailed (-67050), while an unsandboxed shell on that
    /// exact path passes (VM, macOS 26.6, 2026-08-26). Notarization is settled
    /// by syspolicyd, which the container cannot reach. So the gate lives where
    /// it works — in `PerchUpdater`, which is also the only side whose verdict
    /// can actually stop an install.
    static let payloadRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and notarized"

    /// What the sandboxed app checks before it quits its own shelf: is this
    /// even a build of ours? It catches the failures worth catching early — a
    /// truncated download, a mirror serving something else, an unsigned build —
    /// and deliberately stops short of the notarization clause it cannot
    /// evaluate. Passing this is not permission to install; it only means the
    /// download is worth handing over.
    static let identityRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""

    struct VerificationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    /// Both sides run this, on the same bytes, minutes apart. The app runs it
    /// so a bad download is reported *before* the shelf goes away; the updater
    /// runs it again because a check the sandboxed side did is not a check —
    /// the file it verified and the file the updater installs are only the same
    /// file if nothing wrote to the container in between.
    static func verify(bundle: URL, requirement requirementText: String = payloadRequirement) throws {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode)
        guard status == errSecSuccess, let code = staticCode else {
            throw VerificationError("the download has no readable code signature (\(status))")
        }
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw VerificationError("could not build the signing requirement (\(status))")
        }
        // Nested code included: the ZIP carries `perch-cli` and the updater
        // itself, and a check that skipped them would wave through a bundle
        // whose wrapper is ours and whose contents are not.
        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
        )
        status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw VerificationError(
                requirementText == payloadRequirement
                    ? "the download is not a notarized Perch build signed by team \(teamID) (\(status))"
                    : "the download isn't a Perch build signed by team \(teamID) (\(status))"
            )
        }
    }
}

/// What the app asks the updater to do. Written to the app's container, read
/// once, then deleted.
struct UpdateRequest: Codable, Equatable {
    /// The version the payload claims to be; the updater re-reads the payload's
    /// own `CFBundleShortVersionString` and refuses a mismatch.
    var version: String
    /// Verified, unzipped `Perch.app` inside the app's container.
    var payloadPath: String
    /// The bundle to replace. Cross-checked against the updater's own enclosing
    /// bundle — a request naming anything else is refused, which is what keeps
    /// an unsandboxed helper from being a general-purpose file mover.
    var targetPath: String
    /// The app's pid, so the updater waits for the shelf to actually be gone.
    var appPID: Int32
    /// Relaunch after the swap. Always true today; false is what a future
    /// "update on quit" would set.
    var relaunch: Bool
    var requestedAt: TimeInterval
}

/// What the updater leaves behind, so the relaunched app can say how it went
/// instead of pretending nothing happened.
struct UpdateResult: Codable, Equatable {
    var version: String
    var succeeded: Bool
    var message: String
    var finishedAt: TimeInterval
}

enum UpdateHandoff {
    static let requestFileName = "update-request.json"
    static let resultFileName = "update-result.json"

    /// The **real** home. Inside the sandbox `NSHomeDirectory()` answers with
    /// the container, so the passwd entry is the only way for either side to
    /// name the same directory (`RicePalette.RiceFiles.home` does this too —
    /// duplicated rather than shared, because the updater compiles none of the
    /// app's UI).
    static var realHome: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/Library/Containers/<id>/Data` — what `NSHomeDirectory()` answers with
    /// inside the sandbox, spelled out for the side that isn't in it.
    static func containerHome(appBundleID: String, realHome: URL = UpdateHandoff.realHome) -> URL {
        realHome
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(appBundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
    }

    /// The app's own `Application Support/Perch`, given whatever home the
    /// caller is entitled to see. Same directory `settings.json` lives in.
    static func supportDirectory(home: URL) -> URL {
        home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("Perch", isDirectory: true)
    }

    /// Whether a payload path is one perch staged. The updater installs from
    /// nowhere else: verifying an arbitrary path and then moving it is a TOCTOU
    /// with a wide window, and the request file lives where any process running
    /// as this user can write.
    static func isStagedPayload(_ payload: URL, home: URL) -> Bool {
        let staging = downloadDirectory(home: home).standardizedFileURL.path
        let candidate = payload.standardizedFileURL.path
        // `hasPrefix` on the string alone would accept `…/UpdatesEvil/x.app`.
        return candidate.hasPrefix(staging + "/")
    }

    static func requestURL(home: URL) -> URL {
        supportDirectory(home: home).appendingPathComponent(requestFileName)
    }

    static func resultURL(home: URL) -> URL {
        supportDirectory(home: home).appendingPathComponent(resultFileName)
    }

    /// The app bundle an updater at `updater` lives inside:
    /// `Perch.app/Contents/Helpers/PerchUpdater.app` → `Perch.app`. This is the
    /// ONLY thing the updater is ever allowed to replace, which is what keeps an
    /// unsandboxed helper from being a general-purpose file mover: a request
    /// naming any other path is refused, and there is no path in — no arguments,
    /// no prompt — that changes this answer.
    static func enclosingAppBundle(ofUpdaterAt updater: URL) -> URL? {
        let candidate = updater            // …/PerchUpdater.app
            .deletingLastPathComponent()   // …/Contents/Helpers
            .deletingLastPathComponent()   // …/Contents
            .deletingLastPathComponent()   // …/Perch.app
        guard candidate.pathExtension == "app",
              updater.pathExtension == "app",
              updater.deletingLastPathComponent().lastPathComponent == "Helpers"
        else { return nil }
        return candidate.standardizedFileURL
    }

    /// Where a download is staged, and the ONLY place the updater will install
    /// from. Caches, not Application Support: a half-downloaded release is
    /// exactly what a Caches directory is for. It is cleared at the start of
    /// the next download and by the updater when it finishes, so a handoff that
    /// dies in between leaves one release's worth of bytes behind and no more.
    static func downloadDirectory(home: URL) -> URL {
        home
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }
}

// MARK: - CalVer

/// Version ordering, shared so the updater's downgrade refusal and the nudge's
/// "is this newer" agree by construction. `UpdateCheck` forwards to these.
enum CalVer {
    /// A build that isn't a release: an Xcode build (whose `MARKETING_VERSION`
    /// is still the project's placeholder) or a `bench try` branch build.
    static func isDev(_ version: String) -> Bool {
        if version == "dev" || version.isEmpty || version.hasSuffix("-dev") { return true }
        return version.range(
            of: "^[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}(-[0-9]+)?$",
            options: .regularExpression
        ) == nil
    }

    /// The zero-padded date compares lexicographically ("2026.07.29" <
    /// "2026.07.30"); the same-day `-N` suffix must compare NUMERICALLY — a
    /// string compare puts "-10" before "-2", which is the silent-never-nudge
    /// bug `UpdateCheckTests` pins.
    static func isNewer(_ candidate: String, than running: String) -> Bool {
        guard !isDev(running) else { return false }
        let c = split(candidate), r = split(running)
        return c.date == r.date ? c.repeatN > r.repeatN : c.date > r.date
    }

    static func split(_ version: String) -> (date: String, repeatN: Int) {
        guard let dash = version.firstIndex(of: "-") else { return (version, 0) }
        return (
            String(version[..<dash]),
            Int(version[version.index(after: dash)...]) ?? 0
        )
    }
}
