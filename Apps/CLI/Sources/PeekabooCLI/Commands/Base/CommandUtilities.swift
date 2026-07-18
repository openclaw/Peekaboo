import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation

// MARK: - Timeout Utilities

/// Execute an async operation with a timeout
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let task = Task {
        try await operation()
    }

    let timeoutTask = Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        task.cancel()
    }

    do {
        let result = try await task.value
        timeoutTask.cancel()
        return result
    } catch {
        timeoutTask.cancel()
        if task.isCancelled {
            throw CaptureError.captureFailure("Operation timed out after \(seconds) seconds")
        }
        throw error
    }
}

private typealias TimeoutRaceResult = Result<any Sendable, any Error>

private final class TimeoutRace: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var continuation: (@Sendable (TimeoutRaceResult) -> Void)?
    private nonisolated(unsafe) var pendingResult: TimeoutRaceResult?
    private nonisolated(unsafe) var completed = false

    nonisolated func setContinuation<T: Sendable>(_ continuation: CheckedContinuation<T, any Error>) {
        let pendingResult: TimeoutRaceResult?
        self.lock.lock()
        if self.completed {
            pendingResult = self.pendingResult
            self.pendingResult = nil
        } else {
            pendingResult = nil
            self.continuation = { result in
                switch result {
                case let .success(value):
                    guard let value = value as? T else {
                        continuation
                            .resume(throwing: PeekabooError.operationError(message: "Timeout result type mismatch"))
                        return
                    }
                    continuation.resume(returning: value)
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }
        }
        self.lock.unlock()

        if let pendingResult {
            self.resume(continuation: continuation, with: pendingResult)
        }
    }

    nonisolated func resume<T: Sendable>(with result: Result<T, any Error>) {
        let result = result.map { value in value as any Sendable }
        let continuation: (@Sendable (TimeoutRaceResult) -> Void)?
        self.lock.lock()
        if self.completed {
            self.lock.unlock()
            return
        }
        self.completed = true
        continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            self.pendingResult = result
        }
        self.lock.unlock()

        continuation?(result)
    }

    private nonisolated func resume<T: Sendable>(
        continuation: CheckedContinuation<T, any Error>,
        with result: TimeoutRaceResult
    ) {
        switch result {
        case let .success(value):
            guard let value = value as? T else {
                continuation.resume(throwing: PeekabooError.operationError(message: "Timeout result type mismatch"))
                return
            }
            continuation.resume(returning: value)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

/// Race an operation against a wall-clock timeout, even if the operation ignores cancellation.
func withCommandTimeout<T: Sendable>(
    seconds: TimeInterval,
    operationName: String,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard seconds > 0 else {
        throw PeekabooError.invalidInput("Timeout must be greater than 0 seconds")
    }

    let race = TimeoutRace()
    let workTask = Task {
        do {
            let value = try await operation()
            race.resume(with: .success(value))
        } catch {
            race.resume(with: Result<T, any Error>.failure(error))
        }
    }

    let timeoutTask = Task.detached {
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } catch {
            return
        }
        race.resume(with: Result<T, any Error>.failure(PeekabooError.timeout(
            operation: operationName,
            duration: seconds
        )))
        workTask.cancel()
    }

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.setContinuation(continuation)
        }
    } onCancel: {
        race.resume(with: Result<T, any Error>.failure(CancellationError()))
        workTask.cancel()
        timeoutTask.cancel()
    }
}

@MainActor
func withMainActorCommandTimeout<T: Sendable>(
    seconds: TimeInterval,
    operationName: String,
    timeoutError: (@Sendable () -> any Error)? = nil,
    desktopMutationWatermarkStore: DesktopMutationWatermarkStore? = nil,
    interactionMutationTracker: InteractionMutationTracker? = nil,
    operation: @escaping @MainActor () async throws -> T
) async throws -> T {
    guard seconds > 0 else {
        throw PeekabooError.invalidInput("Timeout must be greater than 0 seconds")
    }

    let race = TimeoutRace()
    let pendingMutation = try desktopMutationWatermarkStore?.beginMutation()
    do {
        try interactionMutationTracker?.retainDurableMutationLease()
    } catch {
        if let desktopMutationWatermarkStore, let pendingMutation {
            try? desktopMutationWatermarkStore.cancelMutation(pendingMutation)
        }
        throw error
    }
    let workTask = Task { @MainActor in
        let result: Result<T, any Error>
        do {
            result = try await .success(operation())
        } catch {
            result = .failure(error)
        }
        if let desktopMutationWatermarkStore, let pendingMutation {
            _ = try? desktopMutationWatermarkStore.completeMutation(pendingMutation)
        }
        _ = try? interactionMutationTracker?.completeDurableMutation(through: Date())
        race.resume(with: result)
    }

    let timeoutTask = Task.detached {
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } catch {
            return
        }
        let error = timeoutError?() ?? PeekabooError.timeout(operation: operationName, duration: seconds)
        race.resume(with: Result<T, any Error>.failure(error))
        workTask.cancel()
    }

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.setContinuation(continuation)
        }
    } onCancel: {
        race.resume(with: Result<T, any Error>.failure(CancellationError()))
        workTask.cancel()
        timeoutTask.cancel()
    }
}

// MARK: - Window Target Extensions

extension WindowIdentificationOptions {
    /// Create a window target from options
    func createTarget() throws -> WindowTarget {
        try self.toWindowTarget()
    }

    /// Select a window from a list based on options
    @MainActor
    func selectWindow(from windows: [ServiceWindowInfo]) -> ServiceWindowInfo? {
        if let windowId {
            windows.first(where: { $0.windowID == windowId })
        } else if let title = windowTitle {
            windows.first { $0.title.localizedCaseInsensitiveContains(title) }
        } else if let index = windowIndex, index < windows.count {
            windows[index]
        } else {
            ObservationTargetResolver.bestWindow(from: windows)
        }
    }

    /// Re-fetch the window info after a mutation so callers report fresh bounds.
    @MainActor
    func refetchWindowInfo(
        services: any PeekabooServiceProviding,
        logger: Logger,
        context: StaticString
    ) async -> ServiceWindowInfo? {
        guard let target = try? self.toWindowTarget() else {
            logger.warn("Failed to refetch window info (\(context)): invalid target")
            return nil
        }

        do {
            let refreshedWindows = try await WindowServiceBridge.listWindows(
                windows: services.windows,
                target: target
            )
            return self.selectWindow(from: refreshedWindows)
        } catch {
            logger.warn("Failed to refetch window info (\(context)): \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Application Resolution

/// Marker protocol for commands that need to resolve applications using injected services.
protocol ApplicationResolver {}

extension ApplicationResolver {
    func resolveApplication(
        _ identifier: String,
        services: any PeekabooServiceProviding
    ) async throws -> ServiceApplicationInfo {
        do {
            return try await services.applications.findApplication(identifier: identifier)
        } catch {
            if identifier.lowercased() == "frontmost" {
                var message = "Application 'frontmost' not found"
                message += "\n\n💡 Note: 'frontmost' is not a valid app name. To work with the currently active app:"
                message += "\n  • Use `see` without arguments to capture current screen"
                message += "\n  • Use `app focus` with a specific app name"
                message += "\n  • Use `--app frontmost` with image/see commands to capture the active window"
                throw PeekabooError.appNotFound(identifier)
            }
            throw error
        }
    }
}

// MARK: - Capture Error Extensions

extension Error {
    /// Convert any error to a CaptureError if possible
    var asCaptureError: CaptureError {
        if let captureError = self as? CaptureError {
            return captureError
        }

        if let peekabooError = self as? PeekabooError {
            switch peekabooError {
            case let .appNotFound(identifier):
                return .appNotFound(identifier)
            case .windowNotFound:
                return .windowNotFound
            default:
                return .unknownError(self.localizedDescription)
            }
        }

        return .unknownError(self.localizedDescription)
    }
}
