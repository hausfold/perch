import Foundation

/// `perch doctor` — what this Mac would tell you if you asked it why the shelf
/// isn't behaving, in the order you'd want to hear it.
///
/// It is the one verb that does **not** need Perch running, and it deliberately
/// never launches it: a doctor that starts the patient can't report on the
/// patient. So it answers from three places the app has no say in — the bundle
/// this tool ships inside, the receipts that name the install cohort, and the
/// group container on disk — and only then knocks once, briefly, to see whether
/// anything answers.
///
/// The first two lines are the block perch's bug form asks for (version,
/// cohort, macOS, Mac), from the same `PerchDiagnostics` the app quotes into
/// that form. That is the point of the verb as much as the checks are: "tell us
/// your version by hand" is the worst field on the form.
enum Doctor {
    /// Short on purpose. `add` waits 15 seconds because it has something to
    /// deliver; a doctor asking "is anything there" has an answer either way,
    /// and the useful one arrives in milliseconds — the app's scan loop is
    /// 150ms. `--wait` is there for a Mac under load.
    static let defaultWait: TimeInterval = 2

    private enum Status: String {
        case ok
        /// Worth knowing, not worth failing over.
        case note
        /// The shelf cannot work in this state.
        case bad

        var mark: String {
            switch self {
            case .ok: return "✓"
            case .note: return "!"
            case .bad: return "✗"
            }
        }
    }

    private struct Check {
        var name: String
        var status: Status
        var detail: String
    }

    // MARK: - Dispatch

    static func run(_ arguments: [String]) -> PerchTool.ExitCode {
        var json = false
        var wait = defaultWait
        var index = arguments.startIndex

        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            switch argument {
            case "--json":
                json = true
            case "--wait":
                guard index < arguments.endIndex,
                      let seconds = TimeInterval(arguments[index]), seconds > 0
                else {
                    complain("--wait needs a positive number of seconds")
                    return .usage
                }
                wait = seconds
                index += 1
            case "--no-launch":
                // Already true, and saying so is not an error: a script that
                // passes it everywhere shouldn't have to special-case doctor.
                break
            default:
                complain(
                    argument.hasPrefix("-")
                        ? "unknown option '\(argument)'"
                        : "doctor takes no arguments — it reports on this Mac"
                )
                return .usage
            }
        }

        let report = examine(wait: wait)
        if json {
            print(object(payload(for: report)))
        } else {
            printReport(report)
        }
        // Every blocking thing a doctor can find here is the same shape — no
        // container, or nothing answering — which is exactly what exit 3 means
        // everywhere else in this tool.
        return report.checks.contains { $0.status == .bad } ? .unavailable : .success
    }

    // MARK: - The examination

    private struct Report {
        var version: String
        var bundleID: String?
        var app: URL?
        var launchServicesApp: URL?
        var tool: URL?
        var install: InstallKind?
        var container: URL
        var containerPresent: Bool
        var running: Bool
        var shelfItems: Int?
        var checks: [Check]
    }

    private static func examine(wait: TimeInterval) -> Report {
        let bundle = PerchAppBundle.enclosing
        let app = bundle?.bundleURL
        let launchServices = PerchAppBundle.launchServices
        let install = app.map { installKind(forAppAt: $0) }

        var checks: [Check] = []

        if let app {
            checks.append(Check(name: "app", status: .ok, detail: app.path))
        } else {
            checks.append(
                Check(
                    name: "app",
                    status: .note,
                    detail:
                        "this tool is not inside a Perch.app, so it can't name a version or an "
                        + "install — usually a build tree. Install perch, or run the copy at "
                        + "Perch.app/Contents/MacOS/perch-cli"
                )
            )
        }

        // The pair that has been misread as a perch bug twice (AGENTS.md): every
        // xcodebuild registers the app it built and nothing unregisters it, so
        // a dev Mac routinely launches a copy out of somebody's DerivedData.
        switch (launchServices, app) {
        case let (launch?, app?) where launch.resolvingSymlinksInPath() != app.resolvingSymlinksInPath():
            checks.append(
                Check(
                    name: "launches",
                    status: .note,
                    detail:
                        "\(launch.path) — NOT the bundle this tool ships in. Launch Services is "
                        + "holding an older or stray registration; every build on this Mac adds one"
                )
            )
        case let (launch?, _):
            checks.append(Check(name: "launches", status: .ok, detail: launch.path))
        case (nil, _):
            checks.append(
                Check(
                    name: "launches",
                    status: .note,
                    detail: "Launch Services knows no installed Perch — the bundle this tool "
                        + "ships in would be launched instead"
                )
            )
        }

        if let install {
            // The cohort's NAME is already in the header line; this row is the
            // sentence that tells someone what to actually run, which is the
            // whole reason a doctor bothers to work the cohort out.
            checks.append(
                Check(
                    name: "install",
                    status: install == .unknown ? .note : .ok,
                    detail: install == .unknown
                        ? "not recognised — this bundle is not in /Applications, ~/Applications, "
                            + "the Nix store or a Caskroom. \(install.settingsNote)"
                        : install.settingsNote
                )
            )
        }

        let container = HandoffClient.groupContainerURL()
        // Two different failures wear the same throw, and they have different
        // recoveries: a container that was never made (open Perch once — it is
        // the app's to make, never a tool's) and one that is there but could
        // not be opened. A doctor that folded them together would send half the
        // people it helps to the wrong fix.
        let containerPresent = FileManager.default.fileExists(atPath: container.path)
        var client: HandoffClient?
        do {
            client = try HandoffClient.unsandboxed()
            checks.append(Check(name: "container", status: .ok, detail: container.path))
        } catch {
            checks.append(
                Check(
                    name: "container",
                    status: .bad,
                    detail: containerPresent
                        ? "\(container.path) is there but could not be opened — \(error.localizedDescription)"
                        : "not there — Perch has never run on this account. Open Perch once; the "
                            + "app makes its own container, and no tool should make it for it"
                )
            )
        }

        let knock = client.map { self.knock(on: $0, wait: wait) } ?? .notAsked
        switch knock {
        case .notAsked:
            checks.append(
                Check(name: "shelf", status: .bad, detail: "not asked — the mailbox above could not be opened")
            )
        case let .broke(reason):
            checks.append(
                Check(
                    name: "shelf",
                    status: .bad,
                    detail: "could not open a request in the mailbox — \(reason)"
                )
            )
        case .silent:
            checks.append(
                Check(
                    name: "shelf",
                    status: .bad,
                    detail:
                        "no Perch answered within \(seconds(wait)) — it isn't running. "
                        + "doctor never launches it; `perch list` would"
                )
            )
        // Running, and old enough that it has no case for the verb we knocked
        // with. Reporting that as "not running" would send someone hunting for
        // a process that is right there; the fix is an update, and nothing else.
        case .tooOld:
            checks.append(
                Check(
                    name: "shelf",
                    status: .note,
                    detail:
                        "answering, but this Perch predates `list` — it can't say what is on the "
                        + "shelf. `perch add` still works. Update Perch"
                )
            )
        case let .answered(items):
            checks.append(
                Check(
                    name: "shelf",
                    status: .ok,
                    detail: items == 1 ? "answering — 1 item on it" : "answering — \(items) items on it"
                )
            )
        }

        return Report(
            version: PerchAppBundle.version,
            bundleID: bundle?.bundleIdentifier,
            app: app,
            launchServicesApp: launchServices,
            tool: PerchAppBundle.executableURL,
            install: install,
            container: container,
            containerPresent: client != nil,
            running: knock.isAnswering,
            shelfItems: knock.items,
            checks: checks
        )
    }

    /// What one knock can find. `tooOld` is the case worth having a name for:
    /// a Perch that predates a verb answers with no entries rather than
    /// ignoring the request, so "it said nothing" and "it isn't there" arrive
    /// as the same silence unless they are told apart here.
    private enum Knock {
        case notAsked
        case silent
        /// The mailbox itself refused the exchange. Never folded into `silent`:
        /// "nothing answered" sends someone looking for a process, and a
        /// container that cannot be written is not that problem at all.
        case broke(String)
        case tooOld
        case answered(Int)

        var isAnswering: Bool {
            switch self {
            case .notAsked, .silent, .broke: return false
            case .tooOld, .answered: return true
            }
        }

        var items: Int? {
            if case let .answered(count) = self { return count }
            return nil
        }
    }

    /// One `list` through the mailbox, with no launch and a short deadline: the
    /// tool's own documented liveness test, since a running app is the only
    /// thing that can answer it. The transaction is closed either way — an
    /// abandoned request is what a stalled doctor must not leave behind.
    private static func knock(on client: HandoffClient, wait: TimeInterval) -> Knock {
        let request: FinderActionRequest
        do {
            request = try client.openRequest(kind: .list)
        } catch {
            return .broke(error.localizedDescription)
        }
        do {
            guard
                let response = try client.waitForAnswer(
                    request.id,
                    deadline: Date().addingTimeInterval(wait)
                )
            else {
                client.abandon(request.id)
                return .silent
            }
            client.acknowledge(request.id)
            guard let entries = response.entries else { return .tooOld }
            return .answered(entries.count)
        } catch {
            client.abandon(request.id)
            return .broke(error.localizedDescription)
        }
    }

    /// The cohort, read the way an *unsandboxed* tool can read it: both receipts
    /// are plain files and nothing here is denied them. The app's own
    /// `detectLive` carries a third signal — haus's theme drop — precisely
    /// because the sandbox can hide the first two from it. That fallback is dead
    /// code out here, so it is not passed.
    private static func installKind(forAppAt app: URL) -> InstallKind {
        let fileManager = FileManager.default
        return InstallKind.detect(
            bundlePath: app.resolvingSymlinksInPath().path,
            home: fileManager.homeDirectoryForCurrentUser.path,
            hasRiceMarker: InstallKind.riceMarkerPaths.contains {
                fileManager.fileExists(atPath: $0)
            },
            hasCaskReceipt: InstallKind.caskReceiptPaths.contains {
                fileManager.fileExists(atPath: $0)
            }
        )
    }

    // MARK: - Reporting

    private static func printReport(_ report: Report) {
        // The two lines perch's bug form asks for, in the order it asks for
        // them, so this stanza can be pasted straight into the issue.
        let cohort = report.install.map { " (\($0.displayName))" } ?? ""
        // "perch unknown" reads as a version called unknown. Say the thing.
        let release = report.version == "unknown" ? "perch, version unknown" : "perch \(report.version)"
        print("\(release)\(cohort)")
        print("macOS \(SystemProfile.operatingSystem) on \(SystemProfile.model)")
        print("")

        let width = report.checks.map(\.name.count).max() ?? 0
        for check in report.checks {
            let padding = String(repeating: " ", count: max(0, width - check.name.count))
            print("\(check.status.mark) \(check.name)\(padding)  \(check.detail)")
        }

        print("")
        let bad = report.checks.filter { $0.status == .bad }.count
        let notes = report.checks.filter { $0.status == .note }.count
        switch (bad, notes) {
        case (0, 0): print("doctor: ready")
        case (0, _): print("doctor: ready, \(notes) to note")
        default: print("doctor: \(bad) blocking, \(notes) to note")
        }
    }

    /// Every key always present — the same contract as `perch list --json`, so
    /// a reader can index without testing for the key first.
    private static func payload(for report: Report) -> [String: Any] {
        [
            "version": report.version,
            "bundleID": report.bundleID ?? NSNull(),
            "app": report.app?.path ?? NSNull(),
            "launchServicesApp": report.launchServicesApp?.path ?? NSNull(),
            "tool": report.tool?.path ?? NSNull(),
            "install": report.install?.rawValue ?? NSNull(),
            "installName": report.install?.displayName ?? NSNull(),
            "updateCommand": report.install?.updateCommand ?? NSNull(),
            "os": SystemProfile.operatingSystem,
            "model": SystemProfile.model,
            "container": report.container.path,
            "containerPresent": report.containerPresent,
            "running": report.running,
            "shelfItems": report.shelfItems ?? NSNull(),
            "ok": !report.checks.contains { $0.status == .bad },
            "checks": report.checks.map {
                ["name": $0.name, "status": $0.status.rawValue, "detail": $0.detail]
            },
        ]
    }

    /// `2s`, `2.5s` — a whole number stays whole.
    private static func seconds(_ interval: TimeInterval) -> String {
        interval == interval.rounded() ? "\(Int(interval))s" : "\(interval)s"
    }
}
