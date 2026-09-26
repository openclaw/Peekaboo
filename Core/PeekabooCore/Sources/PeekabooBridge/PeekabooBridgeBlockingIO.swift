import Dispatch

/// Runs bounded socket work without occupying Swift's cooperative executor.
enum PeekabooBridgeBlockingIO {
    typealias Enqueue = @Sendable (@escaping @Sendable () -> Void) -> Void

    nonisolated static func enqueue(_ operation: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async(execute: operation)
    }

    nonisolated static func run<Value: Sendable>(
        enqueue: Enqueue = Self.enqueue,
        _ operation: @escaping @Sendable () throws -> Value) async throws -> Value
    {
        // Do not return early on cancellation: the caller still owns descriptors borrowed by this work.
        try await withCheckedThrowingContinuation { continuation in
            enqueue {
                do {
                    try continuation.resume(returning: operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
