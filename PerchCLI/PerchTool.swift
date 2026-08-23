import AppKit
import Foundation

/// The `perch` command line tool: the scriptable way onto the shelf, and the
/// reference implementation of the App Group handoff protocol for anything else
/// that wants to be one (see docs/cli.md).
///
/// It is a *client* of the running app, not a second shelf. Perch is sandboxed
/// and cannot read a path you merely name, so the tool — unsandboxed, running
/// as you — does the reading: it asks for admission by name, copies only what
/// the app reserved into the shared container, and publishes relative paths.
/// The source is opened read-only and never moved, renamed, or written to, and
/// no original path ever reaches the app.
struct PerchTool {
    enum ExitCode: Int32 {
        /// Every path asked for landed on the shelf.
        case success = 0
        /// Bad usage, or a path that isn't there.
        case usage = 1
        /// Perch is running but turned items away. Nothing in a free, uncapped
        /// perch refuses an offer today; the code stays because the admission
        /// receipt can say no and a caller shouldn't have to guess it can't.
        case refused = 2
        /// No Perch answered in time.
        case unavailable = 3
        /// Perch admitted the items but a copy failed.
        case failed = 4
    }

    private struct Options {
        var paths: [String] = []
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

    let arguments: [String]

    func run() -> ExitCode {
        guard let verb = arguments.first else {
            printUsage(to: .standardError)
            return .usage
        }
        switch verb {
        case "add":
            return runAdd(Array(arguments.dropFirst()))
        case "-h", "--help", "help":
            printUsage(to: .standardOutput)
            return .success
        case "-V", "--version", "version":
            print(version)
            return .success
        default:
            complain("unknown command '\(verb)'")
            printUsage(to: .standardError)
            return .usage
        }
    }

    // MARK: - add

    private func runAdd(_ arguments: [String]) -> ExitCode {
        let options: Options
        do {
            options = try parse(arguments)
        } catch let error as ParseError {
            complain(error.message)
            printUsage(to: .standardError)
            return .usage
        } catch {
            complain(error.localizedDescription)
            return .usage
        }

        guard !options.paths.isEmpty else {
            complain("add needs at least one path")
            printUsage(to: .standardError)
            return .usage
        }

        // Resolve everything before opening a request. A batch that is half
        // typos would otherwise spend shelf slots deciding that.
        var sources: [URL] = []
        var missing: [String] = []
        for path in options.paths {
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
            return .unavailable
        }

        let request: FinderActionRequest
        do {
            request = try client.openRequest(
                displayNames: sources.map(\.lastPathComponent)
            )
        } catch {
            complain(error.localizedDescription)
            return .failed
        }

        do {
            // The mailbox is the liveness test, not a process list: a shelf may
            // be running under a dev bundle identifier, and either way only the
            // app that answers can admit anything. Give a live one a moment
            // first — its scan loop is 150ms — and launch only if none does.
            // With --no-launch there is no second window, so that first one is
            // the whole `--wait` the caller asked for.
            var response = try client.waitForAdmission(
                request.id,
                deadline: options.launch
                    ? min(deadline, Date().addingTimeInterval(2))
                    : deadline
            )
            if response == nil, options.launch {
                launchPerch()
                response = try client.waitForAdmission(request.id, deadline: deadline)
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
                return .unavailable
            }

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

    // MARK: - Reaching the app

    /// Prefer whatever Launch Services considers the installed Perch — that is
    /// the copy holding this account's permissions — and fall back to the app
    /// bundle this tool is embedded in, which is how a dev build (its own
    /// bundle identifier, unknown to Launch Services) still finds itself.
    private func perchAppURL() -> URL? {
        if let installed = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: FinderActionProtocol.appBundleIdentifier
        ) {
            return installed
        }
        return enclosingAppBundle?.bundleURL
    }

    /// The `.app` this tool ships inside, found by walking up from its own
    /// *resolved* executable path rather than by trusting `Bundle.main`.
    ///
    /// Every installer puts the tool on `PATH` as a **symlink** into the
    /// bundle — `nix/package.nix` here, the cask's `binary` stanza, haus's
    /// shelf room — because it is signed and notarized as part of the app and
    /// a copy outside it would be nested code torn out of that seal. Invoked
    /// through such a link, `Bundle.main` is the *link's* directory: no
    /// Info.plist, no `.app` extension. That made `perch --version` print
    /// `unknown` on every install that isn't the raw in-bundle path, and left
    /// this launch fallback with nothing to open.
    private var enclosingAppBundle: Bundle? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }
        // …/Perch.app/Contents/MacOS/perch-cli → …/Perch.app
        let app =
            executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard app.pathExtension == "app" else { return nil }
        return Bundle(url: app)
    }

    private func launchPerch() {
        guard let url = perchAppURL() else { return }
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

    private func json(for outcomes: [Outcome]) -> String {
        func entries(_ include: (Outcome) -> [String: String]?) -> [[String: String]] {
            outcomes.compactMap(include)
        }
        let payload: [String: Any] = [
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
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Arguments

    private struct ParseError: Error {
        let message: String
    }

    private func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = arguments.startIndex
        var literal = false

        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            guard !literal else {
                options.paths.append(argument)
                continue
            }
            switch argument {
            case "--":
                literal = true
            case "--json":
                options.json = true
            case "--quiet", "-q":
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
                options.paths.append(contentsOf: pathsFromStandardInput())
            default:
                guard !argument.hasPrefix("--") else {
                    throw ParseError(message: "unknown option '\(argument)'")
                }
                options.paths.append(argument)
            }
        }
        return options
    }

    /// `find . -name '*.png' | perch add -` — one path per line, so a path with
    /// spaces survives the pipe.
    private func pathsFromStandardInput() -> [String] {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var version: String {
        enclosingAppBundle?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private func complain(_ message: String) {
        FileHandle.standardError.write(Data("perch: \(message)\n".utf8))
    }

    private enum Stream {
        case standardOutput
        case standardError
    }

    private func printUsage(to stream: Stream) {
        let usage = """
        usage: perch add [options] <path>...

        Copies files onto the running Perch shelf. Originals are only read.

        options:
          --wait <seconds>  how long to wait for Perch to answer (default 15)
          --no-launch       fail instead of launching Perch when it isn't running
          --json            report the result as JSON on stdout
          --quiet, -q       don't print a line per added file
          -                 read newline-separated paths from stdin
          --                treat every remaining argument as a path

        other commands:
          perch --version   print the installed release
          perch help        this text

        exit status:
          0 added   1 usage   2 refused   3 no Perch   4 copy failed
        """
        switch stream {
        case .standardOutput:
            print(usage)
        case .standardError:
            FileHandle.standardError.write(Data((usage + "\n").utf8))
        }
    }
}
