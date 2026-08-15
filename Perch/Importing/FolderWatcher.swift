import CryptoKit
import Foundation

/// Which files a watched folder is willing to shelve. Pure, so the rules are
/// testable without a filesystem. See ADR 0010.
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

    /// A file's identity for the import ledger: inode and birth date, hashed.
    /// Survives rename and edit-in-place, changes when the file is recreated,
    /// and never encodes a name or a path.
    static func identityToken(forFileAt url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let digest = SHA256.hash(data: Data("\(inode):\(created)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
/// stream's. See ADR 0010.
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
        onLedgerReplaced: @escaping @Sendable (Set<String>) -> Void
    ) {
        self.folderID = folderID
        self.folderURL = folderURL
        self.ledger = ledger
        self.holdsSecurityScope = holdsSecurityScope
        self.probeInterval = probeInterval
        self.requiredStableProbes = requiredStableProbes
        self.onImport = onImport
        self.onLedgerReplaced = onLedgerReplaced
        queue = DispatchQueue(label: "com.hausfold.perch.folderwatch.\(folderID.uuidString)")
    }

    /// Opens the directory and begins watching. `seedExisting` marks
    /// everything already present as imported without shelving it — the
    /// just-added case; a relaunch instead prunes the ledger and catches up
    /// on unledgered arrivals.
    ///
    /// Returns false when the folder cannot be opened at all.
    func start(seedExisting: Bool) -> Bool {
        if holdsSecurityScope {
            scopeActive = folderURL.startAccessingSecurityScopedResource()
        }
        let descriptor = open(folderURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            releaseScope()
            return false
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scan()
        }
        source.setCancelHandler { [weak self] in
            close(descriptor)
            self?.releaseScope()
        }
        self.source = source
        source.resume()
        queue.async { [weak self] in
            self?.initialScan(seedExisting: seedExisting)
        }
        return true
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
        ledger.insert(token)
        onImport(url, token)
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
