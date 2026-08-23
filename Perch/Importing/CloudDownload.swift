import Foundation

/// What one look at a ubiquitous item says about its local copy.
enum CloudDownloadProgress: Equatable, Sendable {
    /// The bytes are local; the copy can start.
    case downloaded
    /// A download is running.
    case downloading
    /// The item is not local and nothing is fetching it — the state that makes
    /// a wedged tile look exactly like a slow one. Distinguished so a timeout
    /// can say which of the two happened.
    case notStarted
}

/// The one thread every cloud syscall runs on.
///
/// Every call the cloud path makes is a *synchronous* file syscall — the
/// "is this evicted?" check on the path of every import, the
/// `startDownloadingUbiquitousItem` request, and a probe every 250 ms for up to
/// two minutes. Called inline from an async function they run on the
/// cooperative pool, which has one thread per core and cannot grow, so fifty
/// files dropped at once put fifty blocking calls on it and starve every other
/// async task in the app — the imports queued behind them included. That is the
/// loose end #2's fix left: leaving the operation queue removed the two-slot cap
/// on concurrent waiters along with the stall it was causing, and
/// `ShelfStore.importFileURLs` spawns one unstructured `Task` per dropped URL
/// with no cap of its own.
///
/// **Bounding the waits instead would be the wrong fix.** iCloud fetches in
/// parallel, so a queued-up waiter would not ask for its download until an
/// earlier one finished, and its 120 s deadline would start late — putting
/// ordinary drops back behind cloud ones is exactly the bug #2's fix removed.
/// What has to be bounded is the *blocking work*, not the waiting: every waiter
/// still runs its own clock, its own deadline and its own download, and only the
/// syscalls are single-file.
///
/// The cost is stated plainly, because serial means head-of-line: one wedged
/// syscall delays every other cloud call behind it. It cannot move a *deadline*
/// — that instant is wall-clock — but the deadline is only **checked** after the
/// probe returns, so a wedged probe delays when a timeout fires and is reported,
/// as well as the elapsed seconds on screen. The calls being serialised are
/// local metadata reads and one daemon request, which is why one lane is enough.
enum CloudSyscallQueue {
    /// `.userInitiated` to match the import pipeline it gates. A queue created
    /// with an explicit lower QoS is *not* raised by an `async` submission —
    /// there is no synchronous waiter to donate priority — so `.utility` here
    /// would run the probe below the import blocked on it, on a throttled I/O
    /// tier, and make the syscall slower than it was inline.
    private static let queue = DispatchQueue(
        label: "com.hausfold.perch.cloud-syscall",
        qos: .userInitiated
    )

    /// Runs one blocking cloud syscall off the cooperative pool, one at a time.
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: work))
            }
        }
    }
}

/// Waits for iCloud to bring an evicted file down.
///
/// Deliberately `async` and poll-based rather than a blocking loop: this is the
/// one import phase that can legitimately last two minutes, and the import
/// queue only has two slots. Holding one of them for a file the user is merely
/// *waiting* on stalls every other drop behind it — the second half of #2.
/// Nothing here touches the main actor; the caller decides where progress
/// lands.
///
/// **There is no percentage to show, and that is not an omission.**
/// `URLResourceKey.ubiquitousItemPercentDownloadedKey` is unavailable in Swift
/// (deprecated since 10.8), and its replacement — `NSMetadataQuery` with
/// `NSMetadataUbiquitousItemPercentDownloadedKey` — only reports on *the
/// querying app's own* ubiquity container. A file the user dragged out of
/// iCloud Drive is in theirs, and perch ships with no iCloud entitlement at
/// all. So the honest signal is elapsed time against a stated deadline, which
/// is what this reports.
struct CloudDownloadWaiter: Sendable {
    var timeout: Duration = .seconds(120)
    var pollInterval: Duration = .milliseconds(250)

    /// Whether this URL is an iCloud item whose bytes are not local yet — the
    /// only kind of drop that waits at all.
    var isUndownloadedCloudItem: @Sendable (URL) throws -> Bool = Self.isUndownloadedUbiquitousItem

    /// Asks iCloud to fetch the item.
    var startDownload: @Sendable (URL) throws -> Void = {
        try FileManager().startDownloadingUbiquitousItem(at: $0)
    }

    /// Reads the item's current state. Injected, with the two above, so the
    /// whole cloud path is testable without an iCloud account.
    var probe: @Sendable (URL) throws -> CloudDownloadProgress = Self.probeUbiquitousItem

    /// - Parameter elapsedChanged: called with whole seconds waited so far,
    ///   once per second, starting at `0`. It is what turns an unbounded
    ///   spinner into something a user can judge.
    /// - Throws: `TransferPipelineError.cloudDownloadFailed` if iCloud
    ///   publishes a download error, `.cloudDownloadNeverStarted` if no probe
    ///   ever saw a download running — iCloud never picked the request up, and
    ///   opening the file in Finder is the way out — or `.cloudDownloadTimedOut`
    ///   if one did run and did not finish within `timeout`. A download that
    ///   starts and then pauses for the rest of the window is a timeout, not a
    ///   never-started: `everRan` latches on the first `.downloading` seen.
    func wait(
        for url: URL,
        elapsedChanged: @Sendable (Int) -> Void
    ) async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: timeout)
        var everRan = false
        var lastElapsed = -1

        while true {
            // Off the cooperative pool and one at a time — see `CloudSyscallQueue`.
            switch try await CloudSyscallQueue.run({ [probe] in try probe(url) }) {
            case .downloaded:
                return
            case .downloading:
                everRan = true
            case .notStarted:
                break
            }

            let elapsed = Int(started.duration(to: clock.now).components.seconds)
            if elapsed != lastElapsed {
                lastElapsed = elapsed
                elapsedChanged(elapsed)
            }

            guard clock.now < deadline else { break }
            try await Task.sleep(for: pollInterval)
        }

        throw everRan
            ? TransferPipelineError.cloudDownloadTimedOut
            : TransferPipelineError.cloudDownloadNeverStarted
    }

    /// Resource values read *without* the cache a `URL` keeps on its underlying
    /// `NSURL` box.
    ///
    /// This is the whole of why #2 looked like "stuck forever". Polling the
    /// same `URL` returns the values it had at the **first** read, however long
    /// you wait and whatever iCloud does — so a file that finished downloading
    /// seconds later still read as `.notDownloaded` until the deadline expired.
    /// `FolderWatcher.probe` documents the identical trap and samples through
    /// `FileManager` to dodge it; this path did not.
    static func uncachedResourceValues(
        of url: URL,
        forKeys keys: Set<URLResourceKey>
    ) throws -> URLResourceValues {
        var url = url
        url.removeAllCachedResourceValues()
        return try url.resourceValues(forKeys: keys)
    }

    /// The production probe. Reads only the download keys — never the path, which
    /// must not be logged or persisted.
    static let probeUbiquitousItem: @Sendable (URL) throws -> CloudDownloadProgress = { url in
        let values = try uncachedResourceValues(of: url, forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemDownloadingErrorKey,
        ])
        if values.ubiquitousItemDownloadingError != nil {
            // Deliberately *not* rethrown. iCloud's own NSError embeds the item's
            // name and path, and `ShelfStore.report` logs `localizedDescription`
            // as `.public` — which would put an original path in the system log.
            throw TransferPipelineError.cloudDownloadFailed
        }
        let status = values.ubiquitousItemDownloadingStatus
        if status == .current || status == .downloaded {
            return .downloaded
        }
        return values.ubiquitousItemIsDownloading == true ? .downloading : .notStarted
    }

    /// The production check. `.current` means "local and up to date"; anything else
    /// — evicted, stale, mid-download — has to be fetched before it can be copied.
    static let isUndownloadedUbiquitousItem: @Sendable (URL) throws -> Bool = { url in
        let values = try uncachedResourceValues(of: url, forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ])
        return values.isUbiquitousItem == true
            && values.ubiquitousItemDownloadingStatus != .current
    }
}
