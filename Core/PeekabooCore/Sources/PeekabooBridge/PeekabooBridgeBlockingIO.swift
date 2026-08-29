import Dispatch

/// Runs bounded socket work without occupying Swift's cooperative executor.
enum PeekabooBridgeBlockingIO {
    nonisolated static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value) async throws -> Value
    {
        // Do not return early on cancellation: the caller still owns descriptors borrowed by this work.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try continuation.resume(returning: operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
