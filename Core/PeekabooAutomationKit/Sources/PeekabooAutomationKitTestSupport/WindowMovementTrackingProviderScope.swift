import PeekabooAutomationKit

/// Serializes process-global window-tracking provider overrides across test suites.
///
/// This scope is deliberately non-reentrant and cancellation-insensitive: every queued operation runs and restores the
/// provider before handing the gate to the next test.
public enum WindowMovementTrackingProviderScope {
    private static let gate = WindowMovementTrackingProviderGate()

    @MainActor
    public static func withProvider<Result>(
        _ provider: any WindowTrackingProviding,
        operation: @MainActor () async throws -> Result) async rethrows -> Result
    {
        try await self.withExclusiveAccess {
            WindowMovementTracking.provider = provider
            return try await operation()
        }
    }

    @MainActor
    public static func withExclusiveAccess<Result>(
        operation: @MainActor () async throws -> Result) async rethrows -> Result
    {
        await self.gate.acquire()
        let previous = WindowMovementTracking.provider
        do {
            let result = try await operation()
            WindowMovementTracking.provider = previous
            await self.gate.release()
            return result
        } catch {
            WindowMovementTracking.provider = previous
            await self.gate.release()
            throw error
        }
    }
}

private actor WindowMovementTrackingProviderGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard self.isHeld else {
            self.isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func release() {
        guard !self.waiters.isEmpty else {
            self.isHeld = false
            return
        }
        self.waiters.removeFirst().resume()
    }
}
