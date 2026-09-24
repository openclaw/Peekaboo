/// Instance-owned admission for a clipboard-backed paste transaction.
public protocol ClipboardPasteTransactionGating: Sendable {
    @MainActor
    func withExclusiveTransaction<T: Sendable>(
        _ operation: () async throws -> T) async throws -> T
}

public struct NativeClipboardPasteTransactionGate: ClipboardPasteTransactionGating {
    public init() {}

    @MainActor
    public func withExclusiveTransaction<T: Sendable>(
        _ operation: () async throws -> T) async throws -> T
    {
        try await ClipboardPasteTransactionGate.withExclusiveTransaction(operation)
    }
}
