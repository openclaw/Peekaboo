import Darwin
import Dispatch
import Foundation

public enum ProcessTerminationDecision: Sendable, Equatable {
    case terminateNow
    case terminateLater
}

/// Joins repeated process-termination requests and replies only after asynchronous shutdown completes.
@MainActor
public final class ProcessTerminationGate {
    public typealias Shutdown = @MainActor @Sendable () async -> Void
    public typealias Reply = @MainActor @Sendable (Bool) -> Void

    private var shutdownTask: Task<Void, Never>?
    private var didComplete = false

    public init() {}

    public func begin(
        shutdown: @escaping Shutdown,
        reply: @escaping Reply) -> ProcessTerminationDecision
    {
        if self.didComplete {
            return .terminateNow
        }
        if self.shutdownTask != nil {
            return .terminateLater
        }

        self.shutdownTask = Task { [weak self] in
            await shutdown()
            guard let self else { return }
            self.didComplete = true
            self.shutdownTask = nil
            reply(true)
        }
        return .terminateLater
    }
}

/// Converts process-termination signals into ordinary callbacks owned by an executable's lifecycle layer.
///
/// This type intentionally does not know about Bridge hosts or process exit. A GUI app or daemon can use the
/// callback to begin its own asynchronous shutdown and keep the process alive until that shutdown completes.
public final class ProcessTerminationSignalSource: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "boo.peekaboo.process-termination-signals")
    private nonisolated(unsafe) var sources: [any DispatchSourceSignal] = []
    private nonisolated(unsafe) var previousHandlers: [(Int32, sig_t?)] = []
    private nonisolated(unsafe) var cancelled = false

    public nonisolated init(
        signals: [Int32] = [SIGINT, SIGTERM],
        onSignal: @escaping @Sendable (Int32) -> Void)
    {
        for signalNumber in signals {
            self.previousHandlers.append((signalNumber, Darwin.signal(signalNumber, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: self.queue)
            source.setEventHandler {
                onSignal(signalNumber)
            }
            source.activate()
            self.sources.append(source)
        }
    }

    public nonisolated func cancel() {
        self.lock.lock()
        guard !self.cancelled else {
            self.lock.unlock()
            return
        }
        self.cancelled = true
        let sources = self.sources
        let previousHandlers = self.previousHandlers
        self.sources.removeAll()
        self.previousHandlers.removeAll()
        self.lock.unlock()

        for source in sources {
            source.cancel()
        }
        for (signalNumber, previousHandler) in previousHandlers {
            Darwin.signal(signalNumber, previousHandler)
        }
    }

    deinit {
        self.cancel()
    }
}
