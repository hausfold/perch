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
        /// Nil while the copy is still running: the identity of a half-written
        /// file is not the identity it will settle at.
        var token: String?
        var stamp: DispatchTime
    }

    private let lock = NSLock()
    private var pending: [String: Entry] = [:]
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
            pending[key] = Entry(token: nil, stamp: .now())
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
            guard let token else {
                // Nothing to match on later; a file we cannot stat is one no
                // watcher will ledger either, so stop pretending we wrote it.
                pending.removeValue(forKey: key)
                return storedOnWritten
            }
            pending[key] = Entry(token: token, stamp: .now())
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
            pending.removeValue(forKey: key)
        }
    }

    /// A watcher found `token` at `url`. Consumes the entry on `.ours`, so a
    /// second sighting of the same file is an ordinary arrival again.
    func claim(_ url: URL, token: String) -> Claim {
        let key = Self.key(for: url)
        return lock.withLock {
            prune()
            guard let entry = pending[key] else { return .unrelated }
            guard let written = entry.token else { return .inFlight }
            // The path is ours but the identity is not: something replaced the
            // file after our copy landed. That is a genuine new arrival.
            guard written == token else { return .unrelated }
            pending.removeValue(forKey: key)
            return .ours
        }
    }

    /// Called with the lock held.
    private func prune() {
        let now = DispatchTime.now()
        pending = pending.filter { _, entry in
            let age = Double(now.uptimeNanoseconds - entry.stamp.uptimeNanoseconds) / 1_000_000_000
            return age < lifetime
        }
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
