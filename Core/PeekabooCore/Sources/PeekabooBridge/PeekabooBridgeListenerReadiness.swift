import Darwin
import Dispatch
import Foundation
import OSLog

/// Converts listener readability into a coalesced async sequence.
///
/// A UNIX listener is level-triggered: one notification can represent several queued clients, so the accept loop
/// drains until `EAGAIN` before waiting for the next event. Keeping the source alive for the listener lifetime avoids
/// a polling sleep and lets shutdown explicitly finish the sequence before the descriptor is closed.
final class PeekabooBridgeListenerReadiness: @unchecked Sendable {
    let events: AsyncStream<Void>

    private let continuation: AsyncStream<Void>.Continuation
    private let cancellationEvents: AsyncStream<Void>
    private let source: any DispatchSourceRead
    private let lock = NSLock()
    private var isCancelled = false
    private var isFinishing = false
    private var isSuspended = false
    private var notificationCount = 0

    init(fileDescriptor: Int32) {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let cancellationPair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.events = pair.stream
        self.continuation = pair.continuation
        self.cancellationEvents = cancellationPair.stream
        self.source = DispatchSource.makeReadSource(
            fileDescriptor: fileDescriptor,
            queue: DispatchQueue.global(qos: .userInitiated))
        self.source.setEventHandler { [weak self] in
            self?.notifyReadable()
        }
        self.source.setCancelHandler {
            close(fileDescriptor)
            cancellationPair.continuation.yield(())
            cancellationPair.continuation.finish()
        }
        self.source.activate()
    }

    deinit {
        self.cancel()
    }

    func cancel() {
        self.lock.lock()
        guard !self.isCancelled else {
            self.lock.unlock()
            return
        }
        self.isCancelled = true
        let mustResume = self.isSuspended
        self.isSuspended = false
        self.lock.unlock()

        // A cancelled Dispatch source does not deliver its cancellation while suspended.
        if mustResume {
            self.source.resume()
        }
        self.continuation.finish()
        self.source.cancel()
    }

    /// Stops the async consumer before source cancellation closes the descriptor.
    func finishEvents() {
        self.lock.lock()
        guard !self.isFinishing else {
            self.lock.unlock()
            return
        }
        self.isFinishing = true
        self.lock.unlock()
        self.continuation.finish()
    }

    /// Waits until all queued source handlers have drained, making it safe for the owner to close the descriptor.
    func waitUntilCancelled() async {
        for await _ in self.cancellationEvents {
            return
        }
    }

    /// Re-enables listener notifications after the accept queue has been drained to `EAGAIN`.
    func rearm() {
        self.lock.lock()
        guard !self.isCancelled, !self.isFinishing, self.isSuspended else {
            self.lock.unlock()
            return
        }
        self.isSuspended = false
        self.lock.unlock()
        self.source.resume()
    }

    #if DEBUG
    var notificationCountForTesting: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.notificationCount
    }
    #endif

    private func notifyReadable() {
        self.lock.lock()
        guard !self.isCancelled, !self.isFinishing, !self.isSuspended else {
            self.lock.unlock()
            return
        }
        // Dispatch read sources are level-triggered. Suspend until the async consumer drains accept(), otherwise a
        // queued client can repeatedly invoke this lightweight handler faster than the consumer gets scheduled.
        self.isSuspended = true
        self.notificationCount += 1
        self.source.suspend()
        self.lock.unlock()
        self.continuation.yield(())
    }
}
