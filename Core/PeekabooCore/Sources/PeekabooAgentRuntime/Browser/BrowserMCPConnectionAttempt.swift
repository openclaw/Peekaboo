import Foundation
import PeekabooFoundation

final class BrowserMCPConnectionAttemptState: @unchecked Sendable {
    private let lock = NSLock()
    private var permissionDispatchStarted = false
    private var connectionDispatchStarted = false

    var didStartPermissionDispatch: Bool {
        self.lock.withLock { self.permissionDispatchStarted }
    }

    var didStartConnectionDispatch: Bool {
        self.lock.withLock { self.connectionDispatchStarted }
    }

    var didStartAnyDispatch: Bool {
        self.lock.withLock { self.permissionDispatchStarted || self.connectionDispatchStarted }
    }

    func markPermissionDispatchStarted() {
        self.lock.withLock { self.permissionDispatchStarted = true }
    }

    func markConnectionDispatchStarted() {
        self.lock.withLock { self.connectionDispatchStarted = true }
    }
}

struct BrowserMCPConnectionAttempt: Sendable {
    let deadline: ContinuousClock.Instant
    let state: BrowserMCPConnectionAttemptState

    static func live() -> Self {
        Self(
            deadline: ContinuousClock.now.advanced(
                by: .seconds(BrowserConnectionTiming.endToEndTimeoutSeconds)),
            state: BrowserMCPConnectionAttemptState())
    }

    static func standalone(timeout: Duration = .seconds(BrowserConnectionTiming.approvalTimeoutSeconds)) -> Self {
        Self(
            deadline: ContinuousClock.now.advanced(by: timeout),
            state: BrowserMCPConnectionAttemptState())
    }
}

enum BrowserMCPConnectionDeadlineError: LocalizedError, Equatable {
    case timedOut

    var errorDescription: String? {
        "The browser connection did not complete before its shared end-to-end deadline."
    }
}

enum BrowserMCPConnectionDeadline {
    @MainActor
    static func run<T: Sendable>(
        until deadline: ContinuousClock.Instant,
        operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T
    {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw BrowserMCPConnectionDeadlineError.timedOut }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: remaining)
                throw BrowserMCPConnectionDeadlineError.timedOut
            }
            guard let value = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return value
        }
    }
}
