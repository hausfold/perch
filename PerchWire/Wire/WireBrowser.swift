import Foundation
import Network

/// One Mac visible on the local network right now.
public struct DiscoveredMac: Sendable {
    public let macID: UUID
    public let name: String
    public let endpoint: NWEndpoint
}

/// Watches Bonjour for shelf-holding Macs. The phone matches Macs by the
/// stable `macid` TXT record, never by address — addresses change, pairings
/// don't.
public final class WireBrowser: @unchecked Sendable {
    /// Waits until the Mac with `macID` shows up, or the timeout runs out.
    ///
    /// Built on an AsyncStream rather than a bare continuation on purpose: a
    /// continuation that only resumes on a match leaks when the Mac never
    /// appears — the task group then waits on it forever, and "Mac away", the
    /// product's headline offline case, becomes a deadlock. Stream iteration
    /// is cancellation-aware, so the timeout can actually win.
    public static func waitFor(macID: UUID, timeout: Duration) async -> NWEndpoint? {
        let browser = WireBrowser()
        defer { browser.stop() }
        let matches = AsyncStream<NWEndpoint> { continuation in
            browser.start { macs in
                if let match = macs.first(where: { $0.macID == macID }) {
                    continuation.yield(match.endpoint)
                }
            }
        }
        return await withTaskGroup(of: NWEndpoint?.self) { group in
            group.addTask {
                for await endpoint in matches {
                    return endpoint
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
    private let lock = NSLock()
    private var browser: NWBrowser?
    private var onChange: (@Sendable ([DiscoveredMac]) -> Void)?

    public init() {}

    public func start(onChange: @escaping @Sendable ([DiscoveredMac]) -> Void) {
        lock.withLock {
            guard browser == nil else {
                self.onChange = onChange
                return
            }
            self.onChange = onChange
            let parameters = NWParameters()
            parameters.includePeerToPeer = true
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: WireProtocol.bonjourType, domain: nil),
                using: parameters
            )
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.publish(results)
            }
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    // A failed browser never recovers; restart it.
                    self?.restart()
                }
            }
            browser.start(queue: .global(qos: .utility))
            self.browser = browser
        }
    }

    public func stop() {
        lock.withLock {
            browser?.cancel()
            browser = nil
            onChange = nil
        }
    }

    private func restart() {
        let handler = lock.withLock { onChange }
        stop()
        if let handler {
            start(onChange: handler)
        }
    }

    private func publish(_ results: Set<NWBrowser.Result>) {
        let macs: [DiscoveredMac] = results.compactMap { result in
            guard case let .bonjour(txt) = result.metadata,
                  let idString = txt["macid"],
                  let macID = UUID(uuidString: idString)
            else {
                return nil
            }
            let name: String
            if case let .service(serviceName, _, _, _) = result.endpoint {
                name = serviceName
            } else {
                name = "Mac"
            }
            return DiscoveredMac(macID: macID, name: name, endpoint: result.endpoint)
        }
        lock.withLock { onChange }?(macs)
    }
}
