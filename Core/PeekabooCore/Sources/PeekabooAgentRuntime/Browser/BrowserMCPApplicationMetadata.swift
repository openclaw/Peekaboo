import Dispatch
import Foundation

/// AppKit application getters can wait on LaunchServices, even when they only read metadata.
enum BrowserMCPApplicationMetadata {
    private static let queue = DispatchQueue(label: "boo.peekaboo.browser-application-metadata", qos: .utility)

    static func read<Value: Sendable>(_ read: @escaping @Sendable () -> Value) async throws -> Value {
        try Task.checkCancellation()
        let state = ReadState<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                self.queue.async {
                    guard !state.isFinished else { return }
                    state.finish(.success(read()))
                }
            }
        } onCancel: {
            state.finish(.failure(CancellationError()))
        }
    }

    private final class ReadState<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, any Error>?
        private var result: Result<Value, any Error>?

        var isFinished: Bool {
            self.lock.withLock { self.result != nil }
        }

        func install(_ continuation: CheckedContinuation<Value, any Error>) {
            let result: Result<Value, any Error>? = self.lock.withLock {
                if let result = self.result {
                    return result
                }
                self.continuation = continuation
                return nil
            }
            if let result {
                continuation.resume(with: result)
            }
        }

        func finish(_ result: Result<Value, any Error>) {
            let continuation: CheckedContinuation<Value, any Error>? = self.lock.withLock {
                guard self.result == nil else { return nil }
                self.result = result
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(with: result)
        }
    }
}
