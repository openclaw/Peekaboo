import Commander
import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation

// MARK: - Timeout Utilities

private final nonisolated class CommandTimeoutTimer: @unchecked Sendable {
    private let workItem: DispatchWorkItem

    init(seconds: TimeInterval, action: @escaping @Sendable () -> Void) {
        let workItem = DispatchWorkItem(block: action)
        self.workItem = workItem
        // Keep the deadline off the cooperative executor, and cancel the work item when another
        // result wins so successful commands do not accumulate later timer-task wakeups.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + seconds,
            execute: workItem
        )
    }

    func cancel() {
        self.workItem.cancel()
    }
}

private func makeCommandTimeoutTimer(
    seconds: TimeInterval,
    race: TimeoutRace,
    workTask: Task<Void, Never>,
    error: @escaping @Sendable () -> any Error
) -> CommandTimeoutTimer {
    CommandTimeoutTimer(seconds: seconds) {
        race.resume(with: Result<Bool, any Error>.failure(error()))
        workTask.cancel()
    }
}

/// Execute an async operation with a timeout
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = TimeoutRace()
    let workTask = Task {
        do {
            let value = try await operation()
            race.resume(with: .success(value))
        } catch {
            race.resume(with: Result<T, any Error>.failure(error))
        }
    }

    let timeoutTimer = makeCommandTimeoutTimer(
        seconds: seconds,
        race: race,
        workTask: workTask,
        error: { CaptureError.captureFailure("Operation timed out after \(seconds) seconds") }
    )

    defer {
        workTask.cancel()
        timeoutTimer.cancel()
    }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.setContinuation(continuation)
        }
    } onCancel: {
        race.resume(with: Result<T, any Error>.failure(CancellationError()))
        workTask.cancel()
        timeoutTimer.cancel()
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

    let timeoutTimer = makeCommandTimeoutTimer(
        seconds: seconds,
        race: race,
        workTask: workTask,
        error: { PeekabooError.timeout(operation: operationName, duration: seconds) }
    )

    defer {
        workTask.cancel()
        timeoutTimer.cancel()
    }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.setContinuation(continuation)
        }
    } onCancel: {
        race.resume(with: Result<T, any Error>.failure(CancellationError()))
        workTask.cancel()
        timeoutTimer.cancel()
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

    let timeoutTimer = makeCommandTimeoutTimer(
        seconds: seconds,
        race: race,
        workTask: workTask,
        error: { timeoutError?() ?? PeekabooError.timeout(operation: operationName, duration: seconds) }
    )

    defer {
        workTask.cancel()
        timeoutTimer.cancel()
    }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.setContinuation(continuation)
        }
    } onCancel: {
        race.resume(with: Result<T, any Error>.failure(CancellationError()))
        workTask.cancel()
        timeoutTimer.cancel()
    }
}

// MARK: - Window Target Extensions

@discardableResult
func validatedMutationSelector(
    _ selector: InteractionTargetSelector,
    allowMissingTarget: Bool = false,
    missingTargetMessage: String = "Either --app, --pid, or --window-id must be specified",
    multipleWindowSelectorsMessage: String =
        "Provide only one of --window-id, --window-title, or --window-index"
) throws
-> InteractionTargetSelector {
    if !selector.hasAnyInput {
        guard allowMissingTarget else {
            throw Commander.ValidationError(missingTargetMessage)
        }
        return selector
    }

    do {
        try selector.validate(policy: .mutationSafe)
        return selector
    } catch let error as InteractionTargetSelector.ValidationError {
        switch error {
        case .invalidWindowID:
            throw Commander.ValidationError("--window-id must be a valid positive CoreGraphics window ID")
        case .missingTarget:
            throw Commander.ValidationError(missingTargetMessage)
        case .invalidWindowIndex:
            throw Commander.ValidationError("--window-index must be 0 or greater")
        case .invalidProcessIdentifier:
            throw Commander.ValidationError("--pid must be a valid positive process ID")
        case let .conflictingProcessIdentifiers(applicationPID, explicitPID):
            throw Commander.ValidationError(
                "Conflicting PIDs: --app specifies PID \(applicationPID) but --pid is \(explicitPID)"
            )
        case .invalidApplicationProcessIdentifier:
            throw Commander.ValidationError("Invalid PID format in --app")
        case .applicationAndProcessIdentifier:
            throw Commander.ValidationError("Provide the application either with --app or --pid, not both")
        case .multipleWindowSelectors:
            throw Commander.ValidationError(multipleWindowSelectorsMessage)
        case .windowSelectorRequiresApplication:
            throw Commander.ValidationError("--window-title and --window-index require --app or --pid")
        case .emptyApplication:
            throw Commander.ValidationError("--app must not be empty")
        case .emptyWindowTitle:
            throw Commander.ValidationError("--window-title must not be empty")
        }
    }
}

extension WindowIdentificationOptions {
    /// Create a window target from options
    func createTarget() throws -> WindowTarget {
        try self.toWindowTarget()
    }

    /// Select exactly one mutation target from a full application inventory.
    ///
    /// Exact title matches take precedence over partial matches, but neither form is allowed to
    /// choose arbitrarily when multiple windows match. Indexes use the canonical inventory index
    /// carried by each window rather than the array's incidental ordering.
    @MainActor
    func selectMutationWindow(
        from windows: [ServiceWindowInfo],
        operation: String
    ) throws -> ServiceWindowInfo {
        try ExactWindowSelectorResolver.select(
            from: windows,
            selector: self.selector,
            operation: operation
        )
    }

    /// Re-fetch the window info after a mutation so callers report fresh bounds.
    @MainActor
    func refetchWindowInfo(
        services: any PeekabooServiceProviding,
        logger: Logger,
        context: StaticString
    ) async -> ServiceWindowInfo? {
        guard let target = try? self.toWindowSelectionTarget() else {
            logger.warn("Failed to refetch window info (\(context)): invalid target")
            return nil
        }

        do {
            let refreshedWindows = try await WindowServiceBridge.listWindows(
                windows: services.windows,
                target: target
            )
            return try self.selectMutationWindow(
                from: refreshedWindows,
                operation: "Window \(context) readback"
            )
        } catch {
            logger.warn("Failed to refetch window info (\(context)): \(error.localizedDescription)")
            return nil
        }
    }
}

/// Shared strict selector used by CLI surfaces that must freeze one exact window before work starts.
enum ExactWindowSelectorResolver {
    @MainActor
    static func select(
        from windows: [ServiceWindowInfo],
        selector: InteractionTargetSelector,
        operation: String
    ) throws -> ServiceWindowInfo {
        let selection = try selector.normalizedWindowSelector(policy: .mutationSafe)
        switch selection {
        case nil:
            guard let window = ObservationTargetResolver.bestWindow(from: windows) else {
                throw ExactWindowSelectorResolutionError(
                    message: "\(operation) found no eligible window. Refresh the window inventory before retrying."
                )
            }
            return window

        case let .id(windowID):
            let matches = windows.filter { $0.windowID == windowID }
            guard matches.count == 1, let window = matches.first else {
                let detail = matches.isEmpty ? "does not identify a window" : "identifies multiple windows"
                throw ExactWindowSelectorResolutionError(
                    message: "\(operation) --window-id \(windowID) \(detail). " +
                        "Refresh the window inventory before retrying."
                )
            }
            return window

        case let .title(title):
            let exactMatches = windows.filter {
                $0.title.compare(title, options: .caseInsensitive) == .orderedSame
            }
            if exactMatches.count == 1, let window = exactMatches.first {
                return window
            }
            if exactMatches.count > 1 {
                throw Self.ambiguousTitle(title, matches: exactMatches, operation: operation)
            }

            let partialMatches = windows.filter { $0.title.localizedCaseInsensitiveContains(title) }
            guard partialMatches.count == 1, let window = partialMatches.first else {
                if partialMatches.isEmpty {
                    throw ExactWindowSelectorResolutionError(
                        message: "\(operation) found no window whose title matches '\(title)'. " +
                            "Refresh the inventory and select a --window-id or valid --window-index."
                    )
                }
                throw Self.ambiguousTitle(title, matches: partialMatches, operation: operation)
            }
            return window

        case let .index(index):
            let matches = windows.filter { $0.index == index }
            guard matches.count == 1, let window = matches.first else {
                let detail = matches.isEmpty ? "is not present" : "is ambiguous"
                throw ExactWindowSelectorResolutionError(
                    message: "\(operation) --window-index \(index) \(detail). " +
                        "Refresh the inventory and select a --window-id."
                )
            }
            return window
        }
    }

    private static func ambiguousTitle(
        _ title: String,
        matches: [ServiceWindowInfo],
        operation: String
    ) -> ExactWindowSelectorResolutionError {
        let candidates = matches.prefix(5).map { "id=\($0.windowID) index=\($0.index) '\($0.title)'" }
            .joined(separator: "; ")
        return ExactWindowSelectorResolutionError(
            message: "\(operation) window title '\(title)' is ambiguous (\(candidates)). " +
                "Select one --window-id or --window-index explicitly."
        )
    }
}

struct ExactWindowSelectorResolutionError: Error, LocalizedError, Sendable, Equatable {
    let message: String

    var errorDescription: String? {
        self.message
    }
}

// MARK: - Application Resolution

/// Marker protocol for commands that need to resolve applications using injected services.
protocol ApplicationResolver {}

extension ApplicationResolver {
    @MainActor
    func resolveApplicationForMutation(
        _ identifier: String,
        services: any PeekabooServiceProviding
    ) async throws -> ServiceApplicationInfo {
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            applications: services.applications
        )
        do {
            return try await planner.plan(identifier: identifier).application
        } catch {
            guard identifier.lowercased() == "frontmost" else {
                if let planningError = error as? DesktopTargetPlanningError {
                    throw planningError.desktopActionFailure
                }
                throw error
            }
            var message = "Application 'frontmost' is not a mutation-safe target"
            message += "\n\n💡 To work with the currently active app:"
            message += "\n  • Use `see` without arguments to capture the current screen"
            message += "\n  • Resolve a concrete name or PID with `app list` before mutation"
            message += "\n  • Use `--app frontmost` only with read-only observation commands that support it"
            throw ValidationError(message)
        }
    }
}
