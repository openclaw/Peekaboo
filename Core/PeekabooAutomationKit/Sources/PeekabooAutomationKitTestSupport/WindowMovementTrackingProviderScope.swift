import PeekabooAutomationKit

/// Serializes process-global window-tracking provider overrides across test suites.
///
/// This scope is deliberately cancellation-insensitive: every queued operation runs and restores the provider before
/// handing the gate to the next test. Nested use, including from a child task that inherited the active scope, fails
/// fast instead of deadlocking. A child task retains inherited ownership for its lifetime and must never enter this
/// scope, even after its parent leaves. Detached tasks do not inherit ownership and must not be awaited here if they
/// enter this scope.
public enum WindowMovementTrackingProviderScope {
    private static let gate = WindowMovementTrackingProviderGate()
    @TaskLocal private static var ownsProviderGate = false

    static func reentrancyViolationMessage() -> String? {
        guard self.ownsProviderGate else { return nil }
        return "WindowMovementTrackingProviderScope cannot be nested or entered from a child task " +
            "that inherited provider-scope ownership"
    }

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
    static func withProvider<Result>(
        _ provider: any WindowTrackingProviding,
        queuedSignal: AsyncTestLatch,
        operation: @MainActor () async throws -> Result) async rethrows -> Result
    {
        try await self.withExclusiveAccess(queuedSignal: queuedSignal) {
            WindowMovementTracking.provider = provider
            return try await operation()
        }
    }

    @MainActor
    public static func withExclusiveAccess<Result>(
        operation: @MainActor () async throws -> Result) async rethrows -> Result
    {
        try await self.withExclusiveAccess(queuedSignal: nil, operation: operation)
    }

    @MainActor
    private static func withExclusiveAccess<Result>(
        queuedSignal: AsyncTestLatch?,
        operation: @MainActor () async throws -> Result) async rethrows -> Result
    {
        if let violation = self.reentrancyViolationMessage() {
            fatalError(violation)
        }
        await self.gate.acquire(queuedSignal: queuedSignal)
        let previous = WindowMovementTracking.provider
        return try await self.$ownsProviderGate.withValue(true) {
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
}

private actor WindowMovementTrackingProviderGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire(queuedSignal: AsyncTestLatch?) async {
        guard self.isHeld else {
            self.isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
            if let queuedSignal {
                Task {
                    await queuedSignal.open()
                }
            }
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
