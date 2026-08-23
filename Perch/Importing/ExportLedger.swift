import Foundation

/// The files perch is writing *out* of the shelf right now, so a watched
/// folder can tell them apart from an arrival.
///
/// A drag-out is a copy, and the copy lands as a brand-new inode — an identity
/// no ledger has seen (`FolderWatchRules.identityToken`). A destination folder
/// perch also watches therefore reads the file the user just took out as a
/// fresh arrival and shelves it straight back. Unpinned, the replacement tile
/// carries the same name as the one that just left, so the drag reads as "it
/// never went away"; pinned, the original stays and the round-trip lands
/// beside it under the de-duplicated name the receiver picked (`foo 2.png`),
/// which is the only reason the loop is visible at all. `~/Downloads` and
/// `~/Desktop` are both the folders people watch and the folders people drag
/// onto, so this is the common case, not the corner.
///
/// Shared and lock-guarded rather than reached through `FolderWatchCenter`: a
/// promise fulfils on an export queue, and the reservation has to be in place
/// before `copyItem` writes its first byte — that write is itself the FSEvents
/// event that starts the scan. A hop to the main actor would race the very
/// scan this exists to beat.
///
/// Nothing here is persisted and nothing here is remembered: an entry lives
/// from the moment a copy is announced until a watcher claims it, and
/// `lifetime` bounds the case where no watcher ever does — a destination
/// outside every watched folder, which is most of them.
final class ExportLedger: @unchecked Sendable {
    /// What a watcher's scan should do with a file it found.
    enum Claim: Equatable {
        /// Not something perch wrote. Import it the usual way.
        case unrelated
        /// Perch is mid-copy at this path. Leave it alone — the bytes are not
        /// all there yet, and its identity is not final either.
        case inFlight
        /// Perch wrote this. Adopt it into the ledger instead of shelving it.
        case ours
    }

    static let shared = ExportLedger()

    /// A completed export needs the watcher over its destination to look
    /// again. Without the nudge a folder that then goes quiet produces no
    /// further event, and the file stays unledgered until some unrelated
    /// arrival wakes the scan — by which point the entry below may have
    /// expired and the round-trip happens after all. Set by
    /// `FolderWatchCenter`.
    var onWritten: (@Sendable (URL) -> Void)? {
        get { lock.withLock { storedOnWritten } }
        set { lock.withLock { storedOnWritten = newValue } }
    }

    private struct Entry {
        /// The identity the file settled at. Nil while the copy is still
        /// running — a half-written file has neither its final bytes nor its
        /// final identity — and also for a copy that finished but could not be
        /// stat'ed, which is held as `.inFlight` until it expires rather than
        /// released into the scan that would shelve it straight back.
        var token: String?
        /// Set by `didWrite`/`cancelWrite`. Only a settled entry expires: a
        /// copy still running is bounded by the copy, not by a clock, and a
        /// multi-gigabyte write onto a slow volume must not have its
        /// reservation pulled out from under it halfway. Nothing here outlives
        /// the process, so a crash mid-copy cleans up by exiting.
        var settled: Bool
        var stamp: DispatchTime
    }

    private let lock = NSLock()
    /// Keyed by destination path — what a watcher scanning its folder has.
    private var pending: [String: Entry] = [:]
    /// Keyed by settled identity, for the receiver that writes into a scratch
    /// directory and *moves* the finished file into place. A move on one
    /// volume carries the inode, the birth date, the size and the modification
    /// date, so the token still matches at a path this never saw.
    private var settledTokens: [String: DispatchTime] = [:]
    private var storedOnWritten: (@Sendable (URL) -> Void)?
    private let lifetime: TimeInterval

    init(lifetime: TimeInterval = 60) {
        self.lifetime = lifetime
    }

    /// A promise is about to copy into `url`. Called before the first byte.
    func willWrite(to url: URL) {
        let key = Self.key(for: url)
        lock.withLock {
            prune()
            pending[key] = Entry(token: nil, settled: false, stamp: .now())
        }
    }

    /// The copy finished. The file's identity is final from here, so record it
    /// — a rename or a move onto the same volume carries the inode, the birth
    /// date, the size and the modification date along with it, so the token
    /// still matches wherever a receiver puts the file next.
    func didWrite(to url: URL) {
        let token = try? FolderWatchRules.identityToken(forFileAt: url)
        let key = Self.key(for: url)
        let notify: (@Sendable (URL) -> Void)? = lock.withLock {
            prune()
            let now = DispatchTime.now()
            // A nil token keeps the reservation rather than dropping it. The
            // file is perch's either way, and releasing it here would wake the
            // scan — `onWritten` fires below — onto the very file the reserve
            // exists to protect. It expires like any other settled entry.
            pending[key] = Entry(token: token, settled: true, stamp: now)
            if let token {
                settledTokens[token] = now
            }
            return storedOnWritten
        }
        notify?(url)
    }

    /// The copy failed, so nothing landed at `url` — or nothing of ours. Drop
    /// the reservation rather than leaving it to expire, or a real arrival at
    /// that path in the next minute would be swallowed.
    func cancelWrite(at url: URL) {
        let key = Self.key(for: url)
        lock.withLock {
            prune()
            if let token = pending.removeValue(forKey: key)?.token {
                settledTokens.removeValue(forKey: token)
            }
        }
    }

    /// A watcher found `token` at `url`. Consumes the entry on `.ours`, so a
    /// second sighting of the same file is an ordinary arrival again.
    func claim(_ url: URL, token: String) -> Claim {
        let key = Self.key(for: url)
        return lock.withLock {
            prune()
            guard let entry = pending[key] else {
                // No reservation at this path, but the identity may still be
                // one perch wrote and a receiver then moved here.
                guard settledTokens.removeValue(forKey: token) != nil else {
                    return .unrelated
                }
                return .ours
            }
            guard let written = entry.token else { return .inFlight }
            // The path is ours but the identity is not: something replaced the
            // file after our copy landed. That is a genuine new arrival — the
            // same "rewritten in place" rule every other watched file follows.
            guard written == token else { return .unrelated }
            pending.removeValue(forKey: key)
            settledTokens.removeValue(forKey: token)
            return .ours
        }
    }

    /// Called with the lock held. Only settled entries age out; see `Entry`.
    private func prune() {
        let now = DispatchTime.now()
        pending = pending.filter { _, entry in
            !entry.settled || Self.age(of: entry.stamp, at: now) < lifetime
        }
        settledTokens = settledTokens.filter { Self.age(of: $0.value, at: now) < lifetime }
    }

    private static func age(of stamp: DispatchTime, at now: DispatchTime) -> TimeInterval {
        Double(now.uptimeNanoseconds - stamp.uptimeNanoseconds) / 1_000_000_000
    }

    /// One spelling of a path, for both sides of the match.
    ///
    /// A receiver hands the promise whatever URL it built, and a watcher lists
    /// its folder with `contentsOfDirectory` — URLs assembled from the folder
    /// URL its bookmark resolved to. The two routinely disagree on symlinks
    /// (`/var` against `/private/var` is the one every temporary directory
    /// walks into) and on trailing spellings, and a key that disagrees matches
    /// nothing and silently does nothing at all. Same canonical form
    /// `FolderWatchCenter` dedupes folders with.
    ///
    /// Safe before the file exists — the leaf has no link to resolve, and the
    /// directory above it does.
    private static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
