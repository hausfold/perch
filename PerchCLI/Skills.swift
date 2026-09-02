import Foundation

/// `perch skill` — the door an agent walks through before it knows perch
/// exists. A3 of the family agent surface (workshop `docs/agent-surface.md`).
///
/// The skill is baked into this binary (`GeneratedSkills.swift`) rather than
/// read from beside it, and that is the whole design: perch ships as a cask's
/// `.app`, as a read-only Nix store path, and as a ZIP somebody drags, and the
/// tool on `PATH` is only ever a symlink into the bundle. Any "read the file
/// next to me" scheme is correct for one of those doors and wrong for the
/// others. Embedded, the version that answers `--version` is the version that
/// answers `skill`.
///
/// `install` writes **every** skill perch ships, one directory per skill named
/// for the skill rather than for the tool — a tool that ships a second skill
/// and installs only its first reaches no standalone user with it. Perch ships
/// one today; the loop is over `GeneratedSkills.all` anyway, because the day it
/// ships two is not the day anyone will remember this.
enum Skills {
    /// Where each agent client reads skills from. The layout inside is the same
    /// for all of them: `<dir>/<skill name>/SKILL.md`.
    enum Client: String, CaseIterable {
        case claude
        case codex
        case opencode
        case pi

        var directory: URL {
            let home = Skills.home
            switch self {
            case .claude: return home.appending(path: ".claude/skills")
            case .codex: return home.appending(path: ".codex/skills")
            case .opencode: return home.appending(path: ".config/opencode/skills")
            case .pi: return home.appending(path: ".pi/agent/skills")
            }
        }

        /// A client counts as installed when its own config directory exists —
        /// the *parent* of the skills directory, which the client itself makes
        /// and we may be the first to fill.
        var isPresent: Bool {
            FileManager.default.fileExists(
                atPath: directory.deletingLastPathComponent().path
            )
        }
    }

    /// `$HOME` first, and that is deliberate. Every other home lookup on this
    /// side of perch goes through Foundation, but on macOS both
    /// `NSHomeDirectory()` and `homeDirectoryForCurrentUser` read the *passwd*
    /// entry and ignore the environment — right for "where does this user's
    /// `~/Applications` live" (which is how `Doctor` asks), wrong here. These
    /// are directories an agent client reads, and a client reads them at the
    /// `$HOME` it was started with; a CLI that ignored it would also be
    /// untestable without writing into a real person's home.
    static var home: URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    // MARK: - Dispatch

    static func run(_ arguments: [String]) -> PerchTool.ExitCode {
        if arguments.first == "install" {
            return install(Array(arguments.dropFirst()))
        }
        return show(arguments)
    }

    // MARK: - perch skill [<name>]

    private static func show(_ arguments: [String]) -> PerchTool.ExitCode {
        var json = false
        var name: String?
        for argument in arguments {
            switch argument {
            case "--json":
                json = true
            case "--client", "--dir":
                complain("\(argument) belongs to `perch skill install`")
                return .usage
            default:
                guard !argument.hasPrefix("-") else {
                    complain("unknown option '\(argument)'")
                    return .usage
                }
                guard name == nil else {
                    complain("skill prints one skill at a time")
                    return .usage
                }
                name = argument
            }
        }

        // No name means the tool's own, which is the first one baked in.
        guard let skill = named(name) else {
            complain(
                "no such skill '\(name ?? "")' — perch ships: "
                    + GeneratedSkills.all.map(\.name).joined(separator: ", ")
            )
            return .usage
        }

        if json {
            print(object(["name": skill.name, "body": contents(of: skill)]))
        } else {
            // `print` supplies the newline the string literal cannot carry, so
            // this is byte-for-byte the committed `ai/SKILL.md`.
            print(skill.body)
        }
        return .success
    }

    // MARK: - perch skill install

    private struct Skipped {
        var path: String
        /// `managed` — something else owns that path (on a haus machine, the
        /// Nix symlink haus.ai.skill put there). `differs` — a real file that
        /// isn't ours, which we will not clobber.
        var reason: String
        var message: String
    }

    private static func install(_ arguments: [String]) -> PerchTool.ExitCode {
        var json = false
        var directory: String?
        var client: String?
        var index = arguments.startIndex

        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            switch argument {
            case "--json":
                json = true
            case "--dir", "--client":
                guard index < arguments.endIndex else {
                    complain("\(argument) needs a value")
                    return .usage
                }
                if argument == "--dir" { directory = arguments[index] } else { client = arguments[index] }
                index += 1
            default:
                complain("unknown option '\(argument)'")
                return .usage
            }
        }

        guard directory == nil || client == nil else {
            complain("--dir and --client name two different places; pass one")
            return .usage
        }

        var targets: [URL] = []
        if let directory {
            targets = [URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)]
        } else if let client {
            guard let known = Client(rawValue: client) else {
                complain(
                    "unknown client '\(client)' — one of: "
                        + Client.allCases.map(\.rawValue).joined(separator: ", ")
                )
                return .usage
            }
            targets = [known.directory]
        } else {
            targets = Client.allCases.filter(\.isPresent).map(\.directory)
        }

        guard !targets.isEmpty else {
            complain(
                "no agent client found on this Mac, so there is nowhere to install to — "
                    + "name a directory with --dir, or a client with --client"
            )
            return .usage
        }

        var written: [String] = []
        var current: [String] = []
        var skipped: [Skipped] = []
        for target in targets {
            for skill in GeneratedSkills.all {
                switch write(skill, into: target) {
                case let .wrote(path): written.append(path)
                case let .current(path): current.append(path)
                case let .skipped(entry): skipped.append(entry)
                }
            }
        }

        if json {
            print(
                object([
                    "written": written,
                    "current": current,
                    "skipped": skipped.map { ["path": $0.path, "reason": $0.reason] },
                ])
            )
        } else {
            for path in written { print("wrote \(path)") }
            // Data, not a diagnostic: "it is already there and it is ours" is
            // the answer to `skill install`, not a complaint about it.
            for path in current { print("current \(path)") }
            for entry in skipped { complain(entry.message) }
        }

        // A path something else manages is the *happy* path on a haus machine —
        // the skill is already there and current. A path that exists with
        // different bytes is a refusal, and an agent needs to hear the
        // difference: the skill it is about to rely on is not the one perch
        // shipped. A write that threw is neither — nothing decided anything,
        // the filesystem said no.
        if skipped.contains(where: { $0.reason == "failed" }) { return .failed }
        return skipped.contains { $0.reason == "differs" } ? .refused : .success
    }

    private enum WriteResult {
        case wrote(String)
        /// Already there, already ours, byte for byte.
        case current(String)
        case skipped(Skipped)
    }

    /// `lstat`, not `stat`: `attributesOfItem` does not follow the link, which
    /// is the whole question being asked.
    private static func isSymbolicLink(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private static func write(_ skill: GeneratedSkills.Skill, into target: URL) -> WriteResult {
        let directory = target.appending(path: skill.name, directoryHint: .isDirectory)
        let destination = directory.appending(path: "SKILL.md")
        let body = contents(of: skill)

        // On a haus machine every one of these is a read-only symlink into the
        // Nix store, put there by `haus.ai.skill`. Say that, rather than making
        // someone work it out from an EPERM.
        if isSymbolicLink(directory) || isSymbolicLink(destination) {
            return .skipped(
                Skipped(
                    path: destination.path,
                    reason: "managed",
                    message:
                        "left \(destination.path) alone — it is a symlink, so something else "
                        + "manages it (on a haus machine haus.ai.skill already installed this)"
                )
            )
        }

        if let existing = try? String(contentsOf: destination, encoding: .utf8) {
            guard existing != body else { return .current(destination.path) }
            return .skipped(
                Skipped(
                    path: destination.path,
                    reason: "differs",
                    message:
                        "left \(destination.path) alone — it exists and differs; "
                        + "compare it with `perch skill \(skill.name)`"
                )
            )
        }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try body.write(to: destination, atomically: true, encoding: .utf8)
            return .wrote(destination.path)
        } catch {
            return .skipped(
                Skipped(
                    path: destination.path,
                    reason: "failed",
                    message: "could not write \(destination.path) — \(error.localizedDescription)"
                )
            )
        }
    }

    // MARK: - The skills themselves

    static func named(_ name: String?) -> GeneratedSkills.Skill? {
        guard let name else { return GeneratedSkills.all.first }
        return GeneratedSkills.all.first { $0.name == name }
    }

    /// The file as it is committed: the literal, plus the single trailing
    /// newline a Swift multiline literal drops. `scripts/check-skills.sh`
    /// guards the other half — that each source ends with exactly one.
    static func contents(of skill: GeneratedSkills.Skill) -> String {
        skill.body + "\n"
    }
}
