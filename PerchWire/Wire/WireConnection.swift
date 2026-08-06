import Foundation
import Network

public enum WireConnectionError: LocalizedError {
    case closed
    case cancelled
    case failed(String)
    case handshakeViolation

    public var errorDescription: String? {
        switch self {
        case .closed: "The connection closed."
        case .cancelled: "The connection was cancelled."
        case let .failed(reason): "The connection failed: \(reason)"
        case .handshakeViolation: "The peer broke the handshake sequence."
        }
    }
}

/// One TCP connection speaking length-prefixed frames, async on both ends.
///
/// Plaintext control frames carry the pairing handshake and the session hello;
/// `secure(_:)` arms the cryptors and everything after travels sealed. The
/// actor serializes senders, so two tasks can't interleave half-frames.
public actor WireConnection {
    private let connection: NWConnection
    private var started = false
    private var sendCryptor: FrameCryptor?
    private var receiveCryptor: FrameCryptor?

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public init(to endpoint: NWEndpoint) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        connection = NWConnection(to: endpoint, using: parameters)
    }

    /// Waits until the connection is ready to carry bytes.
    public func start() async throws {
        guard !started else { return }
        started = true
        let connection = connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // stateUpdateHandler fires repeatedly; resume exactly once.
                let resumed = ResumeGuard()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if resumed.claim() { continuation.resume() }
                    case let .failed(error):
                        if resumed.claim() {
                            continuation.resume(throwing: WireConnectionError.failed(error.localizedDescription))
                        }
                    case .cancelled:
                        if resumed.claim() {
                            continuation.resume(throwing: WireConnectionError.cancelled)
                        }
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Arms both directions with session keys. Every frame from here on is
    /// sealed; a plaintext frame after this point fails to open and kills the
    /// connection, which is the intended outcome.
    public func secure(send: FrameCryptor, receive: FrameCryptor) {
        sendCryptor = send
        receiveCryptor = receive
    }

    public var isSecured: Bool {
        sendCryptor != nil
    }

    public func send(_ payload: WirePayload) async throws {
        var bytes = try payload.encoded()
        if sendCryptor != nil {
            bytes = try sendCryptor!.seal(bytes)
        }
        try await sendRaw(try WireFrame.prefixed(bytes))
    }

    /// Handshake-only: send a control message before the channel is secured.
    public func sendPlaintext(_ message: WireMessage) async throws {
        guard sendCryptor == nil else { throw WireConnectionError.handshakeViolation }
        try await sendRaw(try WireFrame.prefixed(try WirePayload.control(message).encoded()))
    }

    public func receive() async throws -> WirePayload {
        let prefix = try await receiveExactly(4)
        let length = try WireFrame.length(fromPrefix: prefix)
        var bytes = length == 0 ? Data() : try await receiveExactly(length)
        if receiveCryptor != nil {
            bytes = try receiveCryptor!.open(bytes)
        }
        return try WirePayload.decoded(from: bytes)
    }

    /// Handshake-only: the next frame must be a plaintext control message.
    public func receivePlaintextMessage() async throws -> WireMessage {
        guard receiveCryptor == nil else { throw WireConnectionError.handshakeViolation }
        guard case let .control(message) = try await receive() else {
            throw WireConnectionError.handshakeViolation
        }
        return message
    }

    /// The next frame must be a control message (secured or not).
    public func receiveMessage() async throws -> WireMessage {
        guard case let .control(message) = try await receive() else {
            throw WireConnectionError.handshakeViolation
        }
        return message
    }

    public func cancel() {
        connection.cancel()
    }

    // MARK: - Raw bytes

    private func sendRaw(_ data: Data) async throws {
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: WireConnectionError.failed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        var collected = Data(capacity: count)
        while collected.count < count {
            let remaining = count - collected.count
            let chunk = try await receiveSome(maximum: remaining)
            collected.append(chunk)
        }
        return collected
    }

    private func receiveSome(maximum: Int) async throws -> Data {
        let connection = connection
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maximum
            ) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: WireConnectionError.failed(error.localizedDescription))
                } else if isComplete {
                    continuation.resume(throwing: WireConnectionError.closed)
                } else {
                    continuation.resume(throwing: WireConnectionError.closed)
                }
            }
        }
    }
}

/// Resume-once latch for Network.framework's repeating state callbacks.
final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
