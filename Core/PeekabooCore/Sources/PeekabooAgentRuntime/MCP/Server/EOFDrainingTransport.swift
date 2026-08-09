import Foundation
import Logging
import MCP

/// Keeps the server's receive stream alive after input EOF until dispatched requests have replied.
///
/// MCP's stdio transport finishes its receive stream as soon as stdin closes. The SDK server handles
/// individual requests in child tasks, so its completion task can otherwise win the race with the
/// final response and let a short-lived CLI process exit before stdout is written.
actor EOFDrainingTransport: Transport {
    nonisolated let logger: Logger

    private let upstream: any Transport
    private let drainTimeout: Duration
    private let messageStream: AsyncThrowingStream<Data, any Error>
    private let messageContinuation: AsyncThrowingStream<Data, any Error>.Continuation

    private var forwardingTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var pendingResponseCounts: [ID: Int] = [:]
    private var reachedInputEOF = false
    private var streamFinished = false

    init(
        wrapping upstream: any Transport,
        drainTimeout: Duration = .seconds(120),
        logger: Logger = Logger(label: "boo.peekaboo.mcp.transport.eof-draining"))
    {
        self.upstream = upstream
        self.drainTimeout = drainTimeout
        self.logger = logger

        var continuation: AsyncThrowingStream<Data, any Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation
    }

    func connect() async throws {
        try await self.upstream.connect()
        guard self.forwardingTask == nil else { return }

        self.forwardingTask = Task { [weak self] in
            await self?.forwardMessages()
        }
    }

    func disconnect() async {
        self.forwardingTask?.cancel()
        self.forwardingTask = nil
        self.drainTask?.cancel()
        self.drainTask = nil
        self.finishStream()
        await self.upstream.disconnect()
    }

    func send(_ data: Data) async throws {
        let responseIDs = Self.responseIDs(in: data)
        do {
            try await self.upstream.send(data)
        } catch {
            self.recordResponsesFinished(responseIDs)
            throw error
        }
        self.recordResponsesFinished(responseIDs)
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        self.messageStream
    }

    private func forwardMessages() async {
        do {
            let upstreamStream = await self.upstream.receive()
            for try await data in upstreamStream {
                if Task.isCancelled {
                    return
                }
                self.recordRequests(in: data)
                self.messageContinuation.yield(data)
            }

            self.reachedInputEOF = true
            self.finishStreamIfDrained()
            self.startDrainDeadlineIfNeeded()
        } catch {
            self.streamFinished = true
            self.messageContinuation.finish(throwing: error)
        }
    }

    private func recordRequests(in data: Data) {
        for id in Self.requestIDs(in: data) {
            self.pendingResponseCounts[id, default: 0] += 1
        }

        for id in Self.cancelledRequestIDs(in: data) {
            self.pendingResponseCounts[id] = nil
        }
    }

    private func recordResponsesFinished(_ ids: [ID]) {
        for id in ids {
            guard let count = self.pendingResponseCounts[id] else { continue }
            if count > 1 {
                self.pendingResponseCounts[id] = count - 1
            } else {
                self.pendingResponseCounts[id] = nil
            }
        }
        self.finishStreamIfDrained()
    }

    private func finishStreamIfDrained() {
        guard self.reachedInputEOF, self.pendingResponseCounts.isEmpty else { return }
        self.finishStream()
    }

    private func startDrainDeadlineIfNeeded() {
        guard !self.streamFinished, self.drainTask == nil else { return }
        let timeout = self.drainTimeout
        self.drainTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.expireDrainDeadline()
        }
    }

    private func expireDrainDeadline() {
        guard !self.streamFinished else { return }
        let message = "MCP input reached EOF with \(self.pendingResponseCounts.count) response IDs still pending; " +
            "ending the receive stream after the drain deadline"
        self.logger.warning("\(message)")
        self.finishStream()
    }

    private func finishStream() {
        guard !self.streamFinished else { return }
        self.streamFinished = true
        self.drainTask?.cancel()
        self.drainTask = nil
        self.messageContinuation.finish()
    }

    private static func requestIDs(in data: Data) -> [ID] {
        self.decodeEnvelopes(from: data).compactMap { envelope in
            guard let id = envelope.id else { return nil }
            return envelope.method != nil || (!envelope.hasResult && !envelope.hasError) ? id : nil
        }
    }

    private static func responseIDs(in data: Data) -> [ID] {
        self.decodeEnvelopes(from: data).compactMap { envelope in
            guard envelope.method == nil, envelope.hasResult || envelope.hasError else { return nil }
            return envelope.id
        }
    }

    private static func cancelledRequestIDs(in data: Data) -> [ID] {
        self.decodeCancellationEnvelopes(from: data).compactMap { envelope in
            guard envelope.method == CancelledNotification.name else { return nil }
            return envelope.params?.requestId
        }
    }

    private static func decodeEnvelopes(from data: Data) -> [MessageEnvelope] {
        let decoder = JSONDecoder()
        if let batch = try? decoder.decode([MessageEnvelope].self, from: data) {
            return batch
        }
        if let message = try? decoder.decode(MessageEnvelope.self, from: data) {
            return [message]
        }
        return []
    }

    private static func decodeCancellationEnvelopes(from data: Data) -> [CancellationEnvelope] {
        let decoder = JSONDecoder()
        if let batch = try? decoder.decode([CancellationEnvelope].self, from: data) {
            return batch
        }
        if let message = try? decoder.decode(CancellationEnvelope.self, from: data) {
            return [message]
        }
        return []
    }
}

private struct MessageEnvelope: Decodable {
    let id: ID?
    let method: String?
    let hasResult: Bool
    let hasError: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case method
        case result
        case error
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(ID.self, forKey: .id)
        self.method = try container.decodeIfPresent(String.self, forKey: .method)
        self.hasResult = container.contains(.result)
        self.hasError = container.contains(.error)
    }
}

private struct CancellationEnvelope: Decodable {
    let method: String?
    let params: CancelledNotification.Parameters?
}
