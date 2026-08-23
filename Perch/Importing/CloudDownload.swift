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
    var isUndownloadedCloudItem: @Sendable (URL) throws -> Bool = isUndownloadedUbiquitousItem

    /// Asks iCloud to fetch the item.
    var startDownload: @Sendable (URL) throws -> Void = {
        try FileManager().startDownloadingUbiquitousItem(at: $0)
    }

    /// Reads the item's current state. Injected, with the two above, so the
    /// whole cloud path is testable without an iCloud account.
    var probe: @Sendable (URL) throws -> CloudDownloadProgress = probeUbiquitousItem

    /// - Parameter elapsedChanged: called with whole seconds waited so far,
    ///   once per second, starting at `0`. It is what turns an unbounded
    ///   spinner into something a user can judge.
    /// - Throws: the iCloud download error if one is published,
    ///   `TransferPipelineError.cloudDownloadNeverStarted` if no download was
    ///   ever running, or `.cloudDownloadTimedOut` if one was and did not
    ///   finish within `timeout`.
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
            switch try probe(url) {
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
}

/// The production probe. Reads only the download keys — never the path, which
/// must not be logged or persisted.
let probeUbiquitousItem: @Sendable (URL) throws -> CloudDownloadProgress = { url in
    let values = try url.resourceValues(forKeys: [
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemDownloadingErrorKey,
    ])
    if let error = values.ubiquitousItemDownloadingError {
        throw error
    }
    let status = values.ubiquitousItemDownloadingStatus
    if status == .current || status == .downloaded {
        return .downloaded
    }
    return values.ubiquitousItemIsDownloading == true ? .downloading : .notStarted
}

/// The production check. `.current` means "local and up to date"; anything else
/// — evicted, stale, mid-download — has to be fetched before it can be copied.
let isUndownloadedUbiquitousItem: @Sendable (URL) throws -> Bool = { url in
    let values = try url.resourceValues(forKeys: [
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
    ])
    return values.isUbiquitousItem == true
        && values.ubiquitousItemDownloadingStatus != .current
}
