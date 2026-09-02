import AppKit
import Foundation

/// The `perch` command line tool: the scriptable way onto the shelf, the way to
/// read it back, and the reference implementation of the App Group handoff
/// protocol for anything else that wants to be one (see docs/cli.md).
///
/// It is a *client* of the running app, not a second shelf. Perch is sandboxed
/// and cannot read a path you merely name, so the tool — unsandboxed, running
/// as you — does the reading: it asks for admission by name, copies only what
/// the app reserved into the shared container, and publishes relative paths.
/// The source is opened read-only and never moved, renamed, or written to, and
/// no original path ever reaches the app.
///
/// `list` and `rm` are the same transaction with nothing to copy in the middle.
/// They deliberately go through the mailbox rather than reading the app's own
/// staging directory: the shelf is the app's to own, and an answer that came
/// from anywhere else could disagree with the tiles on the notch.
///
/// `doctor` and `skill` are the two verbs that are *not* about the shelf, and
/// they live in `Doctor.swift` and `Skills.swift`. Neither needs a running app:
/// doctor reports on this Mac (and refuses to launch anything, so that what it
/// reports stays true), and skill prints the routing document baked into this
/// binary. This file keeps the dispatch, the exit codes and the usage text, so
/// there is one place that says what `perch` can be asked.
struct PerchTool {
    enum ExitCode: Int32 {
        /// Every path asked for landed on the shelf; the shelf was printed;
        /// every named item is off it.
        case success = 0
        /// Bad usage, a path that isn't there, or an id that didn't come off
        /// the shelf.
        case usage = 1
        /// Perch is running but turned items away. Nothing in a free, uncapped
        /// perch refuses an offer today; the code stays because the admission
        /// receipt can say no and a caller shouldn't have to guess it can't.
        case refused = 2
        /// No Perch answered in time — or the one that did is too old to know
        /// the verb, which is the same recovery: get a current Perch running.
        case unavailable = 3
        /// The exchange broke: the container could not be written, or — the
        /// only way `add` gets here — the items were admitted and a copy failed.
        case failed = 4
    }

    /// What the tool can ask the shelf for. `help`, `version`, `doctor` and
    /// `skill` never open a transaction, so they aren't here.
    private enum Verb: String {
        case add
        case list
        case rm

        var kind: FinderActionKind {
            switch self {
            case .add: .add
            case .list: .list
            case .rm: .remove
            }
        }

        /// `add` takes paths and `rm` takes shelf ids; `list` asks a question
        /// and takes nothing. The same split decides which verbs read stdin and
        /// which can be quietened — `list`'s output *is* its answer.
        var takesOperands: Bool { self != .list }
    }

    private struct Options {
        /// Paths for `add`, shelf item ids for `rm`.
        var operands: [String] = []
        var json = false
        var quiet = false
        var launch = true
        var wait: TimeInterval = 15
    }

    private enum Outcome {
        case added(name: String, path: String)
        case refused(name: String, path: String)
        case failed(name: String, path: String, reason: String)
    }

    /// The result of reaching the app: either Perch answered — and the caller
    /// owns the open transaction until it acknowledges — or the attempt is over
    /// and the reason has already been printed.
    private enum Exchange {
        case answered(
            client: HandoffClient,
            request: FinderActionRequest,
            response: FinderActionResponse
        )
        case gaveUp(ExitCode)
    }

    let arguments: [String]

    func run() -> ExitCode {
        guard let verb = arguments.first else {
            printUsage(to: .standardError)
            return .usage
        }
        let rest = Array(arguments.dropFirst())
        switch verb {
        case "add":
            return runAdd(rest)
        case "list":
            return runList(rest)
        case "rm":
            return runRemove(rest)
        // Neither of these opens a transaction: `doctor` knocks once and never
        // launches anything, and `skill` never touches the mailbox at all.
        case "doctor":
            return Doctor.run(rest)
        case "skill":
            return Skills.run(rest)
        case "-h", "--help", "help":
            printUsage(to: .standardOutput)
            return .success
        case "-V", "--version", "version":
            print(PerchAppBundle.version)
            return .success
        default:
            complain("unknown command '\(verb)'")
            printUsage(to: .standardError)
            return .usage
        }
    }

    // MARK: - add

    private func runAdd(_ arguments: [String]) -> ExitCode {
        guard let options = options(from: arguments, for: .add) else { return .usage }

        guard !options.operands.isEmpty else {
            complain("add needs at least one path")
            printUsage(to: .standardError)
            return .usage
        }

        // Resolve everything before opening a request. A batch that is half
        // typos would otherwise spend shelf slots deciding that.
        var sources: [URL] = []
        var missing: [String] = []
        for path in options.operands {
            let url = URL(
                fileURLWithPath: (path as NSString).expandingTildeInPath
            ).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) {
                sources.append(url)
            } else {
                missing.append(path)
            }
        }
        guard missing.isEmpty else {
            for path in missing { complain("no such file: \(path)") }
            return .usage
        }

        switch ask(.add, displayNames: sources.map(\.lastPathComponent), options: options) {
        case let .gaveUp(code):
            return code
        case let .answered(client, request, response):
            do {
                let accepted = Set(response.acceptedItemIDs)
                var staged: [FinderActionStagedItem] = []
                var failedIDs: [UUID] = []
                var outcomes: [Outcome] = []

                for item in request.items {
                    // `attachmentIndex` is this batch's own ordering, and it is
                    // how a sender finds the source behind an admitted item.
                    let source = sources[item.attachmentIndex]
                    guard accepted.contains(item.id) else {
                        outcomes.append(.refused(name: item.displayName, path: source.path))
                        continue
                    }
                    do {
                        staged.append(
                            try client.stage(
                                sourceURL: source,
                                item: item,
                                requestID: request.id
                            )
                        )
                        outcomes.append(.added(name: item.displayName, path: source.path))
                    } catch {
                        failedIDs.append(item.id)
                        outcomes.append(
                            .failed(
                                name: item.displayName,
                                path: source.path,
                                reason: error.localizedDescription
                            )
                        )
                    }
                }

                try client.finish(
                    FinderActionCompletion(stagedItems: staged, failedItemIDs: failedIDs),
                    for: request.id
                )
                report(outcomes, options: options)
                return exitCode(for: outcomes)
            } catch {
                // Same contract as the timeout path: an empty completion is what
                // releases any slots Perch reserved — without it a throw here
                // leaves stuck `.copying` tiles for the full abandonment window.
                client.abandon(request.id)
                complain(error.localizedDescription)
                return .failed
            }
        }
    }

    // MARK: - list

    private func runList(_ arguments: [String]) -> ExitCode {
        guard let options = options(from: arguments, for: .list) else { return .usage }
        guard options.operands.isEmpty else {
            complain("list takes no arguments — it prints the whole shelf")
            printUsage(to: .standardError)
            return .usage
        }

        switch ask(.list, options: options) {
        case let .gaveUp(code):
            return code
        case let .answered(client, request, response):
            defer { client.acknowledge(request.id) }
            guard let entries = response.entries else {
                complain(tooOld(for: .list))
                return .unavailable
            }
            report(shelf: entries, options: options)
            return .success
        }
    }

    // MARK: - rm

    private func runRemove(_ arguments: [String]) -> ExitCode {
        guard let options = options(from: arguments, for: .rm) else { return .usage }
        guard !options.operands.isEmpty else {
            complain("rm needs at least one item id — `perch list` prints them")
            printUsage(to: .standardError)
            return .usage
        }

        // Same rule as a batch of paths: the whole thing is refused before
        // anything is submitted, because a typo'd id is not a removal.
        var ids: [UUID] = []
        var malformed: [String] = []
        for operand in options.operands {
            if let id = UUID(uuidString: operand) {
                ids.append(id)
            } else {
                malformed.append(operand)
            }
        }
        guard malformed.isEmpty else {
            for operand in malformed {
                complain("not a shelf item id: \(operand) — `perch list` prints them")
            }
            return .usage
        }

        switch ask(.rm, targetItemIDs: ids, options: options) {
        case let .gaveUp(code):
            return code
        case let .answered(client, request, response):
            defer { client.acknowledge(request.id) }
            guard let removed = response.entries else {
                complain(tooOld(for: .rm))
                return .unavailable
            }
            let missing = ids.filter { id in !removed.contains { $0.id == id } }
            report(removed: removed, missing: missing, options: options)
            // An id that didn't come back is the `rm(1)` bargain: everything
            // that could go is off the shelf, and the status still says one of
            // the ids didn't.
            return missing.isEmpty ? .success : .usage
        }
    }

    // MARK: - Reaching the app

    /// Everything up to Perch's answer, and identical for every verb: find the
    /// container, publish the request, then give a live shelf a moment to
    /// answer before launching one. A `.gaveUp` result has already said why.
    private func ask(
        _ verb: Verb,
        displayNames: [String] = [],
        targetItemIDs: [UUID] = [],
        options: Options
    ) -> Exchange {
        let deadline = Date().addingTimeInterval(options.wait)
        var client = try? HandoffClient.unsandboxed()
        if client == nil, options.launch {
            // No container at all: perch has never run on this account, and it
            // is the app's job to make its own. Launching is the fix.
            launchPerch()
            client = waitForClient(until: deadline)
        }
        guard let client else {
            complain("Perch's shared container isn't there. Open Perch once.")
            return .gaveUp(.unavailable)
        }

        let request: FinderActionRequest
        do {
            request = try client.openRequest(
                kind: verb.kind,
                displayNames: displayNames,
                targetItemIDs: targetItemIDs
            )
        } catch {
            complain(error.localizedDescription)
            return .gaveUp(.failed)
        }

        do {
            // The mailbox is the liveness test, not a process list: a shelf may
            // be running under a dev bundle identifier, and either way only the
            // app that answers can admit anything. Give a live one a moment
            // first — its scan loop is 150ms — and launch only if none does.
            // With --no-launch there is no second window, so that first one is
            // the whole `--wait` the caller asked for.
            var response = try client.waitForAnswer(
                request.id,
                deadline: options.launch
                    ? min(deadline, Date().addingTimeInterval(2))
                    : deadline
            )
            if response == nil, options.launch {
                launchPerch()
                response = try client.waitForAnswer(request.id, deadline: deadline)
            }
            guard let response else {
                // Perch may have written its answer while we were giving up, so
                // hand back an empty completion rather than deleting the
                // request: that is what releases any slots it reserved.
                client.abandon(request.id)
                complain(
                    options.launch
                        ? "no Perch answered within \(Int(options.wait))s."
                        : "no Perch answered within \(Int(options.wait))s (--no-launch)."
                )
                return .gaveUp(.unavailable)
            }
            return .answered(client: client, request: request, response: response)
        } catch {
            client.abandon(request.id)
            complain(error.localizedDescription)
            return .gaveUp(.failed)
        }
    }

    /// A shelf that answered without entries is one that predates the read
    /// verbs: it heard a verb it has no case for and said so the only way the
    /// protocol allows. The recovery is the same as no answer at all.
    private func tooOld(for verb: Verb) -> String {
        "the Perch that answered is older than `\(verb.rawValue)` — update it."
    }

    private func launchPerch() {
        guard let url = PerchAppBundle.launchTarget else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        // The shelf is a menu-bar app; a script adding a file should not steal
        // the front-most window from whatever the user is doing.
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// The group container is made by the app, not by us: an unsandboxed tool
    /// creating it first would leave the sandboxed app a directory it did not
    /// make. So wait for a just-launched Perch to produce one.
    private func waitForClient(until deadline: Date) -> HandoffClient? {
        repeat {
            if let client = try? HandoffClient.unsandboxed() { return client }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return nil
    }

    // MARK: - Reporting

    private func exitCode(for outcomes: [Outcome]) -> ExitCode {
        if outcomes.contains(where: { if case .failed = $0 { true } else { false } }) {
            return .failed
        }
        if outcomes.contains(where: { if case .refused = $0 { true } else { false } }) {
            return .refused
        }
        return .success
    }

    /// Paths printed here are the caller's own arguments, echoed back on the
    /// caller's own stdout. They are never written into the mailbox and never
    /// reach Perch — see HandoffClient.
    private func report(_ outcomes: [Outcome], options: Options) {
        if options.json {
            print(json(for: outcomes))
            return
        }
        for outcome in outcomes {
            switch outcome {
            case let .added(name, _):
                if !options.quiet { print("added \(name)") }
            case let .refused(name, _):
                complain("refused \(name) — Perch turned it away")
            case let .failed(name, _, reason):
                complain("failed \(name) — \(reason)")
            }
        }
    }

    /// One line per tile, id first, because the id is what `rm` takes.
    private func report(shelf entries: [FinderActionEntry], options: Options) {
        if options.json {
            print(object(["items": entries.map(payload(for:))]))
            return
        }
        guard !entries.isEmpty else {
            // Stdout stays empty so a pipe reads as empty, but a person who
            // asked what is on the shelf still gets an answer.
            complain("the shelf is empty")
            return
        }
        let width = entries.map(\.displayName.count).max() ?? 0
        for entry in entries {
            var trailing: [String] = []
            if let byteCount = entry.byteCount {
                trailing.append(
                    ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
                )
            }
            if entry.isPinned { trailing.append("pinned") }
            var line = "\(entry.id.uuidString)  \(entry.displayName)"
            if !trailing.isEmpty {
                // Padded by hand: `padding(toLength:)` measures UTF-16 and would
                // truncate a name whose emoji count for more than one unit. Only
                // when something follows, so no line ends in whitespace.
                line += String(repeating: " ", count: max(0, width - entry.displayName.count))
                line += "  " + trailing.joined(separator: "  ")
            }
            print(line)
        }
    }

    private func report(removed: [FinderActionEntry], missing: [UUID], options: Options) {
        if options.json {
            print(
                object([
                    "removed": removed.map(payload(for:)),
                    "missing": missing.map(\.uuidString),
                ])
            )
            return
        }
        if !options.quiet {
            for entry in removed { print("removed \(entry.displayName)") }
        }
        for id in missing {
            // Absent from the answer, which is either "never on the shelf" or
            // "Perch could not take it off" — the shelf itself says which.
            complain("not removed: \(id.uuidString) — it isn't on the shelf")
        }
    }

    private func json(for outcomes: [Outcome]) -> String {
        func entries(_ include: (Outcome) -> [String: String]?) -> [[String: String]] {
            outcomes.compactMap(include)
        }
        return object([
            "added": entries {
                if case let .added(name, path) = $0 { ["name": name, "path": path] } else { nil }
            },
            "refused": entries {
                if case let .refused(name, path) = $0 {
                    ["name": name, "path": path, "reason": "refused"]
                } else {
                    nil
                }
            },
            "failed": entries {
                if case let .failed(name, path, reason) = $0 {
                    ["name": name, "path": path, "reason": reason]
                } else {
                    nil
                }
            },
        ])
    }

    /// Every key is always present — `bytes` and `contentType` are null rather
    /// than absent — so a reader can index without testing for the key first.
    private func payload(for entry: FinderActionEntry) -> [String: Any] {
        let stamps = ISO8601DateFormatter()
        return [
            "id": entry.id.uuidString,
            "name": entry.displayName,
            "kind": entry.kind,
            "contentType": entry.contentTypeIdentifier ?? NSNull(),
            "bytes": entry.byteCount ?? NSNull(),
            "addedAt": stamps.string(from: entry.addedAt),
            "pinned": entry.isPinned,
        ]
    }

    // MARK: - Arguments

    private struct ParseError: Error {
        let message: String
    }

    /// Parse, or print why it couldn't and answer nil — every verb's first line.
    private func options(from arguments: [String], for verb: Verb) -> Options? {
        do {
            return try parse(arguments, for: verb)
        } catch let error as ParseError {
            complain(error.message)
            printUsage(to: .standardError)
            return nil
        } catch {
            complain(error.localizedDescription)
            return nil
        }
    }

    private func parse(_ arguments: [String], for verb: Verb) throws -> Options {
        var options = Options()
        var index = arguments.startIndex
        var literal = false

        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            guard !literal else {
                options.operands.append(argument)
                continue
            }
            switch argument {
            case "--":
                literal = true
            case "--json":
                options.json = true
            case "--quiet", "-q":
                guard verb.takesOperands else {
                    throw ParseError(message: "\(verb.rawValue) has no --quiet: its output is the answer")
                }
                options.quiet = true
            case "--no-launch":
                options.launch = false
            case "--wait":
                guard index < arguments.endIndex,
                      let seconds = TimeInterval(arguments[index]), seconds > 0
                else {
                    throw ParseError(message: "--wait needs a positive number of seconds")
                }
                options.wait = seconds
                index += 1
            case "-":
                guard verb.takesOperands else {
                    throw ParseError(message: "\(verb.rawValue) reads nothing from stdin")
                }
                options.operands.append(contentsOf: operandsFromStandardInput())
            default:
                guard !argument.hasPrefix("--") else {
                    throw ParseError(message: "unknown option '\(argument)'")
                }
                options.operands.append(argument)
            }
        }
        return options
    }

    /// `find . -name '*.png' | perch add -`, and the same trick for ids:
    /// `perch list --json | jq -r '.items[].id' | perch rm -`. One per line, so
    /// a path with spaces survives the pipe.
    private func operandsFromStandardInput() -> [String] {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private enum Stream {
        case standardOutput
        case standardError
    }

    private func printUsage(to stream: Stream) {
        let usage = """
        usage: perch add [options] <path>...
               perch list [options]
               perch rm [options] <item-id>...
               perch doctor [--json] [--wait <seconds>]
               perch skill [--json] [<name>]
               perch skill install [--json] [--client <name>] [--dir <path>]

        add     copies files onto the running Perch shelf. Originals are only read.
        list    prints what is on the shelf, id first — those ids are what rm takes.
        rm      takes items off the shelf. The bytes it staged go; yours never do.
        doctor  what this Mac can say about perch — version, install, container,
                whether the shelf answers. Needs no shelf running, and starts none.
        skill   prints the agent skill baked into this binary. `skill install`
                writes it into every agent client here (claude, codex, opencode, pi).

        options:
          --wait <seconds>  how long to wait for Perch to answer (15; doctor 2)
          --no-launch       fail instead of launching Perch when it isn't running
          --json            report the result as JSON on stdout
          --quiet, -q       don't print a line per item (add, rm)
          -                 read newline-separated operands from stdin (add, rm)
          --                treat every remaining argument as an operand
          --client <name>   write into one client's skills dir (skill install)
          --dir <path>      write into this directory instead (skill install)

        other commands:
          perch --version   print the installed release
          perch help        this text

        exit status:
          0 done
          1 usage, a missing path, an unknown skill, or an item that wasn't removed
          2 Perch refused the items — or `skill install` would have overwritten a
            SKILL.md that differs, and left it alone
          3 no Perch answered; for doctor, something blocking
          4 the exchange broke — or a skill could not be written
        """
        switch stream {
        case .standardOutput:
            print(usage)
        case .standardError:
            FileHandle.standardError.write(Data((usage + "\n").utf8))
        }
    }
}
