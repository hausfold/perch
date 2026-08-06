import Foundation
import Network

/// Finds the paired Mac and empties the phone's outbox onto it. Used by the
/// app (live, whenever the Mac appears) and by the Share extension (one
/// bounded attempt before it yields back to the host app).
enum MobileDelivery {
    enum Outcome: Sendable {
        /// Every waiting item was stored by the Mac.
        case delivered(Int)
        /// Some or all items are still waiting (Mac away, or a failure).
        case waiting(Int, reason: String?)
        case nothingWaiting
        case notPaired
    }

    /// One bounded discover-connect-deliver pass.
    static func flush(
        shelf: MobileShelf,
        pairing: MacPairingStore,
        discoveryTimeout: Duration = .seconds(4)
    ) async -> Outcome {
        guard let mac = pairing.pairedMac() else { return .notPaired }
        let waiting = shelf.waitingItems()
        guard !waiting.isEmpty else { return .nothingWaiting }

        guard let endpoint = await discover(macID: mac.id, timeout: discoveryTimeout) else {
            return .waiting(waiting.count, reason: nil)
        }
        return await deliver(waiting, from: shelf, to: endpoint, mac: mac)
    }

    /// Waits until the paired Mac shows up on Bonjour, or the timeout runs out.
    static func discover(macID: UUID, timeout: Duration) async -> NWEndpoint? {
        await WireBrowser.waitFor(macID: macID, timeout: timeout)
    }

    static func deliver(
        _ items: [ShelfItem],
        from shelf: MobileShelf,
        to endpoint: NWEndpoint,
        mac: PairedPeer
    ) async -> Outcome {
        let identity = MobileConfig.deviceIdentity()
        var outgoing: [OutgoingItem] = []
        for item in items {
            if let offer = try? shelf.offer(for: item) {
                outgoing.append(offer)
            }
        }
        guard !outgoing.isEmpty else { return .nothingWaiting }

        let delivered = DeliveredCounter()
        do {
            try await WireTransferClient.deliver(
                outgoing,
                to: endpoint,
                deviceID: identity.id,
                deviceKey: mac.deviceKey
            ) { event in
                if case let .stored(itemID) = event {
                    shelf.markDelivered(itemID)
                    delivered.increment()
                }
            }
        } catch {
            let count = delivered.value
            return .waiting(outgoing.count - count, reason: error.localizedDescription)
        }
        let count = delivered.value
        let remaining = outgoing.count - count
        return remaining == 0
            ? .delivered(count)
            : .waiting(remaining, reason: "The Mac refused some items.")
    }
}

/// Counter that can be bumped from a @Sendable event callback.
final class DeliveredCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}
