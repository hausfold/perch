import CryptoKit
import Foundation
import OSLog

/// Which files a watched folder is willing to shelve. Pure, so the rules are
/// testable without a filesystem.
enum FolderWatchRules {
    /// The names browsers give a download that is not finished. Completion is
    /// announced by renaming past these, and the rename is a directory event.
    static let inProgressExtensions: Set<String> = [
        "download", "crdownload", "part", "partial", "tmp",
    ]

    static func isCandidateName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix(".") else { return false }
        return !inProgressExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Tags the token's recipe. A ledger written by an older perch cannot be
    /// compared with tokens from a newer one — the hash inputs changed — and a
    /// ledger that silently fails to match means every file in the folder
    /// reads as a new arrival. `FolderWatcher.initialScan` looks for this and
    /// re-seeds instead. Bump it whenever `identityToken`'s inputs change.
    static let tokenFormat = "v2"

    static func isCurrentFormat(_ token: String) -> Bool {
        token.hasPrefix("\(tokenFormat):")
    }

    /// A file's identity for the import ledger: inode, birth date, **size and
    /// modification date**, hashed. Survives a rename; changes when the file is
    /// recreated *or rewritten in place*; never encodes a name or a path.
    ///
    /// The content half is load-bearing. `curl -o ~/Downloads/x.bin` truncates
    /// and rewrites an existing path — same inode, same birth date — so an
    /// identity built from those two alone deduped every later download to that
    /// name against the first one, forever, and the file never appeared again
    /// (#6). A browser dodged it only by writing `…​.crdownload` and renaming to
    /// a fresh name each time. Replaced contents are a new arrival; see
    /// `docs/reference.md`.
    static func identityToken(forFileAt url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        // A mount reporting neither inode nor birth date (some network
        // filesystems) would collapse every file into one identity and shelve
        // only the first arrival ever. Fall back to the name — hashed, never
        // stored — and give up rename-stability there instead.
        let origin = (inode == 0 && created == 0)
            ? "name:\(url.lastPathComponent)"
            : "\(inode):\(created)"
        let digest = SHA256.hash(data: Data("\(origin):\(size):\(modified)".utf8))
        return "\(tokenFormat):" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// One watched folder: a kqueue directory source, a rescan per event, and a
/// size-stability probe per candidate so a half-written file never reaches
/// the shelf. Everything runs on one serial queue; callbacks arrive there too
/// and the center hops them to the main actor.
///
/// kqueue rather than FSEvents on purpose: a directory source fires on entry
/// changes (create, rename, delete), a rescan is needed anyway for launch
/// catch-up and ledger pruning, and content writes to a growing file — which
/// a directory kqueue does not report — are the probe's job, not the event
/// stream's.
final class FolderWatcher: @unchecked Sendable {
    let folderID: UUID

    private let folderURL: URL
    private let holdsSecurityScope: Bool
    private let probeInterval: TimeInterval
    private let requiredStableProbes: Int
    /// An arrival held still — hand it to import. Called on the watcher queue.
    private let onImport: @Sendable (URL, String) -> Void
    /// Seeding or launch pruning rewrote the ledger. Called on the watcher queue.
    private let onLedgerReplaced: @Sendable (Set<String>) -> Void
    /// The folder could not be opened for watching. Called on the watcher queue.
    private let onUnavailable: @Sendable () -> Void
    private let logger = Logger(subsystem: "com.hausfold.perch", category: "WatchedFolders")

    private let queue: DispatchQueue
    private var source: DispatchSourceFileSystemObject?
    private var scopeActive = false
    private var stopped = false
    private var ledger: Set<String>
    private var probes: [String: ProbeSample] = [:]

    private struct ProbeSample: Equatable {
        var size: Int
        var modified: Date
        var stableCount: Int = 0
    }

    init(
        folderID: UUID,
        folderURL: URL,
        ledger: Set<String>,
        holdsSecurityScope: Bool = true,
        probeInterval: TimeInterval = 0.5,
        requiredStableProbes: Int = 2,
        onImport: @escaping @Sendable (URL, String) -> Void,
        onLedgerReplaced: @escaping @Sendable (Set<String>) -> Void,
        onUnavailable: @escaping @Sendable () -> Void = {}
    ) {
        self.folderID = folderID
        self.folderURL = folderURL
        self.ledger = ledger
        self.holdsSecurityScope = holdsSecurityScope
        self.probeInterval = probeInterval
        self.requiredStableProbes = requiredStableProbes
        self.onImport = onImport
        self.onLedgerReplaced = onLedgerReplaced
        self.onUnavailable = onUnavailable
        queue = DispatchQueue(label: "com.hausfold.perch.folderwatch.\(folderID.uuidString)")
    }

    /// Opens the directory and begins watching. `seedExisting` marks
    /// everything already present as imported without shelving it — the
    /// just-added case; a relaunch instead prunes the ledger and catches up
    /// on unledgered arrivals. A folder that cannot be opened reports through
    /// `onUnavailable`.
    ///
    /// All of it happens on the watcher queue: `open` on an unreachable
    /// network volume can block, and the caller may be the main actor.
    func start(seedExisting: Bool) {
        queue.async { [self] in
            guard !stopped, source == nil else { return }
            if holdsSecurityScope {
                scopeActive = folderURL.startAccessingSecurityScopedResource()
            }
            let descriptor = open(folderURL.path, O_EVTONLY)
            guard descriptor >= 0 else {
                releaseScope()
                onUnavailable()
                return
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.scan()
            }
            // The cancel handler captures the URL and scope flag by value,
            // never `self` — by the time it runs, the last strong reference
            // to a stopped watcher is usually gone, and a weakly-captured
            // `self` would silently skip releasing the scope, leaking one
            // kernel security-scope grant per stop.
            let scopedURL = scopeActive ? folderURL : nil
            source.setCancelHandler {
                close(descriptor)
                scopedURL?.stopAccessingSecurityScopedResource()
            }
            scopeActive = false
            self.source = source
            source.resume()
            initialScan(seedExisting: seedExisting)
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            probes.removeAll()
            source?.cancel()
            source = nil
        }
    }

    // MARK: - Scanning (watcher queue only)

    private func initialScan(seedExisting: Bool) {
        guard !stopped else { return }
        let current = currentTokens()
        if seedExisting {
            ledger = current
            onLedgerReplaced(ledger)
            return
        }
        // A ledger from an older token format matches nothing in `current`, so
        // pruning would empty it and the scan below would import the folder's
        // entire contents at once. Adopt what is there instead — the same thing
        // adding the folder does. Costs one launch's catch-up, once ever, and
        // only for a folder that was already being watched across the upgrade.
        if !ledger.isEmpty, ledger.contains(where: { !FolderWatchRules.isCurrentFormat($0) }) {
            // Says why a launch did no catch-up, once ever, per folder. A
            // count only — the folder's path lives in its bookmark and nowhere
            // else, least of all in a log.
            logger.info(
                "Watched folder ledger upgraded; adopted \(current.count, privacy: .public) existing file(s) instead of importing them"
            )
            ledger = current
            onLedgerReplaced(ledger)
            return
        }
        // A token whose file is gone can never fire again; dropping it keeps
        // the ledger bounded by what the folder actually holds.
        let surviving = ledger.intersection(current)
        if surviving != ledger {
            ledger = surviving
            onLedgerReplaced(ledger)
        }
        scan()
    }

    private func scan() {
        guard !stopped else { return }
        for url in regularFiles() {
            let name = url.lastPathComponent
            guard FolderWatchRules.isCandidateName(name),
                  probes[url.path] == nil,
                  let token = try? FolderWatchRules.identityToken(forFileAt: url),
                  !ledger.contains(token)
            else {
                continue
            }
            probes[url.path] = ProbeSample(size: -1, modified: .distantPast)
            probe(url)
        }
    }

    /// One `stat` every `probeInterval` until size and modification date hold
    /// still twice in a row. A file that never settles — a live log — is
    /// probed indefinitely and imported never; each round is one cheap stat.
    private func probe(_ url: URL) {
        guard !stopped, var previous = probes[url.path] else { return }
        // Sampled through FileManager, never `url.resourceValues` — a URL
        // caches resource values on its underlying NSURL box, so re-sampling
        // the captured URL would see the size it had at the first probe
        // forever and promote a still-growing file as "stable".
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date
        else {
            // Gone or unreadable mid-probe; a later rename event starts over.
            probes.removeValue(forKey: url.path)
            return
        }
        if size == previous.size, modified == previous.modified {
            previous.stableCount += 1
        } else {
            previous = ProbeSample(size: size, modified: modified)
        }
        // `stableCount` counts agreeing *re*-samples, so N stable probes means
        // N+1 sightings of the same size — the first sample can never promote.
        if previous.stableCount + 1 >= requiredStableProbes {
            probes.removeValue(forKey: url.path)
            promote(url)
            return
        }
        probes[url.path] = previous
        queue.asyncAfter(deadline: .now() + probeInterval) { [weak self] in
            self?.probe(url)
        }
    }

    private func promote(_ url: URL) {
        // Re-derive identity at the moment of import: the path could have been
        // replaced by a different file while the probe watched it.
        guard let token = try? FolderWatchRules.identityToken(forFileAt: url),
              !ledger.contains(token)
        else {
            return
        }
        // Held in memory from here so a second event for the same file cannot
        // start a second import while this one is in flight. It reaches the
        // *persisted* ledger only once staging says it landed — see
        // `forgetImport`.
        ledger.insert(token)
        onImport(url, token)
    }

    /// Staging refused or failed this arrival: take the token back out, so the
    /// next directory event probes and imports the file again.
    ///
    /// Without this a single transient failure — a volume that blinked, a
    /// staging error — made that file permanently invisible to the watcher,
    /// because the ledger recorded the *attempt*.
    func forgetImport(_ token: String) {
        queue.async { [self] in
            guard !stopped else { return }
            ledger.remove(token)
        }
    }

    private func regularFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    }

    private func currentTokens() -> Set<String> {
        Set(regularFiles().compactMap { try? FolderWatchRules.identityToken(forFileAt: $0) })
    }

    private func releaseScope() {
        if scopeActive {
            folderURL.stopAccessingSecurityScopedResource()
            scopeActive = false
        }
    }
}
