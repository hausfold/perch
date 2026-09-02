import AppKit
import Foundation

/// The in-product door to perch's bug form.
///
/// There is no telemetry in anything we ship and there never will be, so the
/// issue form is not one feedback channel among several — it is the only one
/// (workshop `docs/bug-reports.md`). A form nobody can find from inside the app
/// is a channel that exists on paper, and "open GitHub, find the right repo of
/// several, find the Issues tab" is three steps a stranger with a broken Mac has
/// agreed to none of.
///
/// So: one menu row, straight onto the form, with the one field perch can
/// answer already answered.
///
/// **Why `?template=bug.yml` and not `?title=&body=`.** A `body=` prefill opens
/// the *blank* editor and walks straight past the designed form — the fields,
/// the "wrong repo? file it anyway" preamble, the labels the form applies. The
/// query has to name the template for any of that to happen. (Pounce's palette
/// command did the `body=` version for a year, written before the forms
/// existed; it is the same drift this file exists to avoid repeating.)
///
/// **Why only `diagnostics`.** The other three fields are the reporter's:
/// `what` is the report, `area` is their guess, `anything` is optional by
/// design. `diagnostics` is the only one the app can answer better than the
/// person can — perch's version, the OS, the Mac, and *how this copy was
/// installed*, which is the thing a reporter can't be expected to know they
/// were asked and is often the answer (a cask copy and a haus-desktop copy fail
/// differently and update differently).
enum BugReport {
    static let repository = "hausfold/perch"

    /// GitHub serves the form off `issues/new` with the template named in the
    /// query. `blank_issues_enabled: false` makes a bare `issues/new` bounce to
    /// the chooser, which is the right landing for someone browsing and the
    /// wrong one for a menu row that already knows this is a bug.
    static let formURL = "https://github.com/\(repository)/issues/new"

    /// Above this, drop the prefill and use the pasteboard instead. GitHub
    /// serves a URL of roughly 8 KB and refuses beyond it; the margin is for
    /// the rest of the query and for a diagnostics block that grows later.
    /// Perch's block is ~150 bytes, so this is a guard rail, not a live path —
    /// it exists so the day someone adds a log tail here the door still opens.
    static let maximumURLLength = 6000

    /// What the form's "Version and macOS" field asks for, verbatim, plus the
    /// install cohort.
    ///
    /// Deliberately three short lines. This lands in a public issue and a
    /// reporter reads it before they hit Submit — anything they would want to
    /// redact does not belong in a field the app filled in for them, which is
    /// why there are no paths, no usernames, and nothing from their shelf —
    /// and why the cohort is quoted through `displayName`, not `rawValue`: the
    /// raw case for the desktop cohort is the word `rice`, which is our old
    /// vocabulary and does not belong in prose a stranger reads.
    static func diagnostics(
        version: String,
        install: InstallKind,
        operatingSystem: String,
        model: String
    ) -> String {
        """
        Perch \(version) (\(install.displayName))
        macOS \(operatingSystem)
        \(model)
        """
    }

    /// The live one.
    @MainActor
    static func diagnostics() -> String {
        diagnostics(
            version: UpdateCheck.shared.perchVersion,
            install: UpdateCheck.shared.installKind,
            operatingSystem: currentOperatingSystem,
            model: currentModel
        )
    }

    /// The two system lines, both from `PerchDiagnostics/SystemProfile.swift` —
    /// shared with `perch doctor` so a pasted doctor and a filed issue spell
    /// the same Mac the same way. Kept as properties here because this is the
    /// name the form's field is written against.
    static var currentOperatingSystem: String { SystemProfile.operatingSystem }

    static var currentModel: String { SystemProfile.model }

    /// Where the menu row goes, and whether the diagnostics had to travel by
    /// pasteboard instead of in the query.
    struct Destination: Equatable {
        var url: URL
        /// Non-nil when the block was too long to prefill: the caller puts this
        /// on the pasteboard and says so, rather than opening a form with a
        /// field the app silently declined to fill.
        var pasteboard: String?
    }

    /// Pure, so the encoding and the length guard are testable without opening
    /// anything.
    ///
    /// The query is assembled by hand rather than through
    /// `URLComponents.queryItems`, which percent-encodes with
    /// `CharacterSet.urlQueryAllowed` and therefore leaves **`+` literal** — and
    /// a literal `+` in a query is decoded as a space by the receiving server,
    /// GitHub included. Nothing in perch's own block contains one today; pounce
    /// prints hotkey combos (`cmd+space`) into the same field, and the standard
    /// is shared, so the escaping is strict here too rather than correct only
    /// by luck. RFC 3986 unreserved characters pass; everything else is encoded.
    static func destination(diagnostics: String) -> Destination {
        let short = "\(formURL)?template=bug.yml"
        let full = "\(short)&diagnostics=\(percentEncoded(diagnostics))"

        if full.count <= maximumURLLength, let url = URL(string: full) {
            return Destination(url: url, pasteboard: nil)
        }
        // Unreachable via `URL(string:)` failing — the short form is a literal —
        // but a menu row that can silently do nothing is worse than one that
        // opens the repo's Issues tab.
        guard let url = URL(string: short) else {
            return Destination(url: URL(string: "https://github.com/\(repository)/issues")!, pasteboard: diagnostics)
        }
        return Destination(url: url, pasteboard: diagnostics)
    }

    /// Unreserved per RFC 3986; everything else percent-encoded, UTF-8 byte by
    /// byte. Strict on purpose — see `destination(diagnostics:)`.
    static func percentEncoded(_ value: String) -> String {
        var out = ""
        for byte in Array(value.utf8) {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39,  // A-Z a-z 0-9
                 0x2D, 0x2E, 0x5F, 0x7E:                 // - . _ ~
                out.append(Character(UnicodeScalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// Open it. The menu row's whole body.
    @MainActor
    static func open() {
        let destination = destination(diagnostics: diagnostics())
        if let pasteboard = destination.pasteboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pasteboard, forType: .string)
        }
        NSWorkspace.shared.open(destination.url)
    }
}
