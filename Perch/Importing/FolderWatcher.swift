import CoreServices
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
    /// the manual on hausfold.co.
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

/// One watched folder: an FSEvents stream, a rescan per event batch, and a
/// size-stability probe per candidate so a half-written file never reaches
/// the shelf. Everything runs on one serial queue — FSEvents delivers there
/// too — and the center hops results to the main actor.
///
/// FSEvents rather than a kqueue directory source, and both halves matter.
/// A directory kqueue fires on entries appearing, disappearing and being
/// renamed; it says nothing when something writes *into* a file already in
/// the folder, which is exactly what `curl -o ~/Downloads/x.bin` does to an
/// existing path (`O_TRUNC`, same inode, same entry). No event, no `scan()`,
/// and the file never lands (#6). FSEvents reports that as `ItemModified`.
/// And its event IDs are durable: resuming a stream from the last ID this
/// folder was scanned at replays what happened while perch was not running
/// (#8), instead of starting blind at `kFSEventStreamEventIdSinceNow`.
///
/// Only the event source changed. The probe, the ledger, `forgetImport` and
/// the `v2` re-seed are the same, and every event still answers with a full
/// `scan()` — which is what makes a dropped or coalesced batch harmless.
///
/// **A watcher must be `stop()`ped.** A C callback cannot hold a weak
/// reference, so the stream's context retains the watcher and `stop()`'s
/// release is what lets it go. One that is simply dropped leaks itself, a
/// live stream still scanning and importing, and one kernel security-scope
/// grant. `FolderWatchCenter` stops every watcher it drops.
final class FolderWatcher: @unchecked Sendable {
    let folderID: UUID

    private let folderURL: URL
    private let holdsSecurityScope: Bool
    private let probeInterval: TimeInterval
    private let requiredStableProbes: Int
    /// How long FSEvents may coalesce a burst before delivering it. Paired
    /// with `kFSEventStreamCreateFlagNoDefer`, so the first event after a
    /// quiet spell still arrives at once and only a storm gets batched.
    private let eventLatency: CFTimeInterval
    /// The floor between two reported stream positions. FSEvents watches a
    /// path *recursively* and `FileEvents` reports every write underneath it,
    /// so a build directory or a sync client working somewhere inside a
    /// watched `~/Desktop` produces a batch every latency window, forever.
    /// Reporting each one would re-encode and atomically rewrite the whole
    /// config that often, on battery. Losing the last few seconds of position
    /// to an abrupt quit costs a slightly wider replay and nothing else.
    private let positionReportInterval: TimeInterval
    /// An arrival held still — hand it to import. Called on the watcher queue.
    private let onImport: @Sendable (URL, String) -> Void
    /// A file perch wrote here itself — ledger it, but shelve nothing. Called
    /// on the watcher queue. See `ExportLedger`.
    private let onAdopt: @Sendable (String) -> Void
    /// Seeding or launch pruning rewrote the ledger. Called on the watcher queue.
    private let onLedgerReplaced: @Sendable (Set<String>) -> Void
    /// This folder is now scanned up to that stream position; persist it so
    /// the next launch resumes there. Called on the watcher queue.
    private let onEventID: @Sendable (UInt64) -> Void
    /// The folder could not be opened for watching. Called on the watcher queue.
    private let onUnavailable: @Sendable () -> Void
    private let logger = Logger(subsystem: "com.hausfold.perch", category: "WatchedFolders")

    /// Which files in this folder perch is writing out of the shelf itself.
    private let exportLedger: ExportLedger

    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?
    /// Where the stream resumes, and nil for a folder perch has never caught
    /// up on — a fresh add, or a config written before stream positions were
    /// persisted. Nil rather than `kFSEventStreamEventIdSinceNow`, which is
    /// `UInt64.max` and so can never be beaten by the high-water comparison
    /// in `handle(eventIDs:count:)`.
    private var resumeEventID: FSEventStreamEventId?
    /// Set while a position is known but deliberately unreported, and cleared
    /// by the trailing report that follows.
    private var unreportedEventID: FSEventStreamEventId?
    private var lastReportedAt: DispatchTime?
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
        sinceEventID: UInt64? = nil,
        holdsSecurityScope: Bool = true,
        probeInterval: TimeInterval = 0.5,
        requiredStableProbes: Int = 2,
        eventLatency: TimeInterval = 0.5,
        positionReportInterval: TimeInterval = 5,
        exportLedger: ExportLedger = .shared,
        onImport: @escaping @Sendable (URL, String) -> Void,
        onAdopt: @escaping @Sendable (String) -> Void = { _ in },
        onLedgerReplaced: @escaping @Sendable (Set<String>) -> Void,
        onEventID: @escaping @Sendable (UInt64) -> Void = { _ in },
        onUnavailable: @escaping @Sendable () -> Void = {}
    ) {
        self.folderID = folderID
        self.folderURL = folderURL
        self.ledger = ledger
        resumeEventID = sinceEventID
        self.holdsSecurityScope = holdsSecurityScope
        self.probeInterval = probeInterval
        self.requiredStableProbes = requiredStableProbes
        self.eventLatency = eventLatency
        self.positionReportInterval = positionReportInterval
        self.exportLedger = exportLedger
        self.onImport = onImport
        self.onAdopt = onAdopt
        self.onLedgerReplaced = onLedgerReplaced
        self.onEventID = onEventID
        self.onUnavailable = onUnavailable
        queue = DispatchQueue(label: "com.hausfold.perch.folderwatch.\(folderID.uuidString)")
    }

    /// Opens the directory and begins watching. `seedExisting` marks
    /// everything already present as imported without shelving it — the
    /// just-added case; a relaunch instead prunes the ledger, resumes the
    /// stream where it left off and catches up on unledgered arrivals. A
    /// folder that cannot be opened reports through `onUnavailable`.
    ///
    /// All of it happens on the watcher queue: `open` on an unreachable
    /// network volume can block, and the caller may be the main actor.
    func start(seedExisting: Bool) {
        queue.async { [self] in
            guard !stopped, stream == nil else { return }
            if holdsSecurityScope {
                scopeActive = folderURL.startAccessingSecurityScopedResource()
            }
            // `FSEventStreamCreate` happily accepts a path that isn't there —
            // it just waits for one to appear — so reachability is still
            // checked by opening the directory, the way the kqueue source
            // used to check it as a side effect of needing a descriptor.
            let descriptor = open(folderURL.path, O_EVTONLY)
            guard descriptor >= 0 else {
                releaseScope()
                onUnavailable()
                return
            }
            close(descriptor)
            // A newly added folder is seeded from what is on disk right now,
            // so replaying its history would be noise; every other start
            // resumes from the position the last session persisted.
            let since = seedExisting
                ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
                : resumeEventID ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
            // The context retains the watcher for exactly as long as the
            // stream lives, and `stop()`'s release is what lets it go. A
            // C callback cannot hold a weak reference, and an unretained one
            // would be a dangling pointer the moment the center dropped its
            // last reference without stopping first.
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: { pointer in
                    guard let pointer else { return nil }
                    return UnsafeRawPointer(Unmanaged<FolderWatcher>.fromOpaque(pointer).retain().toOpaque())
                },
                release: { pointer in
                    guard let pointer else { return }
                    Unmanaged<FolderWatcher>.fromOpaque(pointer).release()
                },
                copyDescription: nil
            )
            // `FileEvents` is what makes a write into an existing file
            // visible at all; `NoDefer` spends the latency window *after* the
            // first event rather than before it, so a lone arrival is not
            // held back by the coalescing budget a burst needs.
            let flags = UInt32(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            )
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                folderWatchEventCallback,
                &context,
                [folderURL.path] as CFArray,
                since,
                eventLatency,
                flags
            ) else {
                releaseScope()
                onUnavailable()
                return
            }
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                releaseScope()
                onUnavailable()
                return
            }
            self.stream = stream
            initialScan(seedExisting: seedExisting)
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            probes.removeAll()
            // Whatever the throttle was still holding: better a position a
            // few seconds old than none. Harmless for a folder being removed
            // — the store no longer has a row to write it to.
            if let unreportedEventID {
                self.unreportedEventID = nil
                onEventID(unreportedEventID)
            }
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                // Drops the context's retain on `self`; the strong capture in
                // this closure is what keeps the rest of the block valid.
                FSEventStreamRelease(stream)
            }
            stream = nil
            // The scope is held for the watcher's whole life now, not handed
            // to a dispatch source's cancel handler: FSEvents keeps no
            // descriptor of ours, so nothing else would ever give it back.
            releaseScope()
        }
    }

    /// One coalesced FSEvents batch. Every batch answers the same way a
    /// directory event used to — a full `scan()` — so a dropped, coalesced or
    /// replayed batch costs a rescan and never a missed file.
    fileprivate func handle(eventIDs: UnsafePointer<FSEventStreamEventId>, count: Int) {
        guard !stopped, count > 0 else { return }
        scan()
        // The end-of-history marker carries id 0, and IDs are only meaningful
        // going forward — so advance on the high-water mark, never blindly on
        // the last entry. Recorded *after* the scan that answered for it: a
        // crash in between replays the batch instead of skipping it.
        var highest: FSEventStreamEventId = 0
        for index in 0..<count where eventIDs[index] > highest {
            highest = eventIDs[index]
        }
        // Any id the stream actually delivered is authoritative, so this moves
        // to it rather than only ever upward. A stored position can be *above*
        // this machine's counter — a restored backup, a volume carried across
        // Macs — and an upward-only guard would then freeze it there forever:
        // every launch resumes from an id with no history and the replay
        // quietly dies for that folder. `> 0` is the end-of-history marker,
        // which carries id zero and is not a position.
        guard highest > 0, highest != resumeEventID else { return }
        resumeEventID = highest
        report(highest)
    }

    /// Hands a stream position out at most every `positionReportInterval`,
    /// with a trailing report so the last one in a burst is never the one
    /// that gets dropped.
    private func report(_ eventID: FSEventStreamEventId) {
        let now = DispatchTime.now()
        if let previous = lastReportedAt {
            let elapsed = Double(now.uptimeNanoseconds - previous.uptimeNanoseconds) / 1_000_000_000
            guard elapsed >= positionReportInterval else {
                guard unreportedEventID == nil else {
                    // A trailing report is already scheduled; it will pick up
                    // whatever the newest position is when it fires.
                    unreportedEventID = eventID
                    return
                }
                unreportedEventID = eventID
                queue.asyncAfter(deadline: .now() + (positionReportInterval - elapsed)) { [weak self] in
                    guard let self, !stopped, let pending = unreportedEventID else { return }
                    unreportedEventID = nil
                    lastReportedAt = .now()
                    onEventID(pending)
                }
                return
            }
        }
        unreportedEventID = nil
        lastReportedAt = now
        onEventID(eventID)
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
                  let token = try? FolderWatchRules.identityToken(forFileAt: url),
                  !ledger.contains(token)
            else {
                continue
            }
            // Asked before the probe guard below, and that order is the whole
            // point: a probe can already be running at this path when perch
            // announces a write to it — a file deleted a moment before the
            // export landed on its name — and a scan that skipped straight
            // past on "already probing" would never read the verdict, promote
            // the export, and hand the item back after all.
            switch exportLedger.claim(url, token: token) {
            case .unrelated:
                break
            case .inFlight:
                // Perch is mid-copy here. Abandon any probe that beat the
                // announcement; `rescan()` settles it once the copy lands.
                probes.removeValue(forKey: url.path)
                continue
            case .ours:
                probes.removeValue(forKey: url.path)
                ledger.insert(token)
                onAdopt(token)
                continue
            }
            guard probes[url.path] == nil else { continue }
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
        // The last gate before staging. `scan()` asks too, but a probe started
        // before perch announced its write is only ever re-examined here.
        switch exportLedger.claim(url, token: token) {
        case .unrelated:
            break
        case .inFlight:
            return
        case .ours:
            ledger.insert(token)
            onAdopt(token)
            return
        }
        // Held in memory from here so a second event for the same file cannot
        // start a second import while this one is in flight. It reaches the
        // *persisted* ledger only once staging says it landed — see
        // `forgetImport`.
        ledger.insert(token)
        onImport(url, token)
    }

    /// Look again now, without waiting for a directory event.
    ///
    /// A finished export is the case that needs it: perch wrote the last byte
    /// itself, so if the folder then goes quiet there is no further event and
    /// the file would sit unclaimed until an unrelated arrival woke the scan.
    func rescan() {
        queue.async { [self] in
            guard !stopped, stream != nil else { return }
            scan()
        }
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

/// FSEvents' C callback: no context beyond `info`, so the watcher is recovered
/// from the retained pointer the stream's context holds. Already on the
/// watcher's serial queue — `FSEventStreamSetDispatchQueue` put it there.
private let folderWatchEventCallback: FSEventStreamCallback = { _, info, count, _, _, eventIDs in
    guard let info else { return }
    Unmanaged<FolderWatcher>.fromOpaque(info)
        .takeUnretainedValue()
        .handle(eventIDs: eventIDs, count: count)
}
