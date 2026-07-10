import Commander
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

/// Commands or runtime contexts that can specify a preferred capture engine.
protocol CaptureEngineConfigurable: AnyObject {
    var captureEngine: String? { get }
}

enum CommanderRuntimeExecutorMessage {
    static let snapshotInvalidationWarning =
        "Warning: The requested action succeeded, but stale UI snapshots could not be invalidated after retry. " +
        "Do not retry the action."
}

enum CommanderRuntimeExecutorError: LocalizedError {
    case snapshotCatchUpFailed(any Error)
    case mutationBarrierFailed(any Error)

    var errorDescription: String? {
        switch self {
        case let .snapshotCatchUpFailed(error):
            "Could not synchronize the selected host's UI snapshot watermark before execution: " +
                "the requested command was not executed, so retrying later is safe. " + error.localizedDescription
        case let .mutationBarrierFailed(error):
            "Could not establish the desktop mutation barrier before execution: " +
                "the requested command was not executed, so retrying later is safe. " + error.localizedDescription
        }
    }
}

@MainActor
enum CommanderRuntimeExecutor {
    static func resolveAndRun(arguments: [String]) async throws {
        let resolved = try CommanderRuntimeRouter.resolve(argv: arguments)
        try await self.run(resolved: resolved)
    }

    static func run(resolved: CommanderResolvedCommand) async throws {
        let command = try CommanderCLIBinder.instantiateCommand(
            type: resolved.type,
            parsedValues: resolved.parsedValues
        )

        if var runtimeCommand = command as? any AsyncRuntimeCommand {
            let runtimeOptions = try CommanderCLIBinder.makeRuntimeOptions(
                from: resolved.parsedValues,
                commandType: resolved.type
            )
            if let capturePreference = runtimeOptions.captureEnginePreference,
               !capturePreference.isEmpty {
                // Respect explicit engine choice; also allow disabling CG globally.
                setenv("PEEKABOO_CAPTURE_ENGINE", capturePreference, 1)
            }
            let runtime = await CommandRuntime.makeDefaultAsync(options: runtimeOptions)
            try await self.catchUpSelectedHostIfNeeded(
                using: runtime,
                required: runtimeOptions.requiresImplicitSnapshotInvalidation ||
                    runtimeOptions.usesPerToolSnapshotInvalidation
            )
            try await DeferredCommandOutput.run(
                bufferingOutput: runtimeOptions.requiresImplicitSnapshotInvalidation
            ) {
                try await self.runWithImplicitSnapshotInvalidation(
                    using: runtime,
                    required: runtimeOptions.requiresImplicitSnapshotInvalidation,
                    requiresCallerBarrier: runtimeOptions.requiresCallerDesktopMutationBarrier
                ) {
                    try await runtimeCommand.run(using: runtime)
                }
            }
            return
        }

        var plainCommand = command
        try await plainCommand.run()
    }

    static func catchUpSelectedHostIfNeeded(
        using runtime: CommandRuntime,
        required: Bool
    ) async throws {
        guard required else { return }
        try Task.checkCancellation()
        let cutoff = runtime.services.snapshots.effectiveImplicitLatestInvalidationWatermark
        try Task.checkCancellation()
        guard let cutoff else { return }
        do {
            _ = try await runtime.services.snapshots.invalidateImplicitLatestSnapshot(
                through: cutoff,
                preserving: nil,
                preservedAt: nil
            )
            try Task.checkCancellation()
        } catch let error as CancellationError {
            throw error
        } catch {
            throw CommanderRuntimeExecutorError.snapshotCatchUpFailed(error)
        }
    }

    /// Everything post-command snapshot invalidation needs; split out from `CommandRuntime` so
    /// the failure policy can be exercised by unit tests without building full runtime services.
    struct SnapshotInvalidationDependencies {
        let tracker: InteractionMutationTracker
        let targets: InteractionObservationInvalidator.MutationTargets
        let logger: Logger
    }

    static func runWithImplicitSnapshotInvalidation<T>(
        using runtime: CommandRuntime,
        required: Bool,
        requiresCallerBarrier: Bool = false,
        operation: () async throws -> T
    ) async throws -> T {
        let dependencies = SnapshotInvalidationDependencies(
            tracker: runtime.interactionMutationTracker,
            targets: runtime.interactionMutationTargets,
            logger: runtime.logger
        )
        let mutationSequenceAtStart = runtime.interactionMutationTracker.mutationSequence
        let needsCallerBarrier = required &&
            (runtime.selectedRemoteSocketPath == nil || requiresCallerBarrier)
        let createdDurableMutation: Bool
        if needsCallerBarrier {
            do {
                createdDurableMutation = try runtime.interactionMutationTracker.beginDurableMutation()
            } catch {
                throw CommanderRuntimeExecutorError.mutationBarrierFailed(error)
            }
        } else {
            createdDurableMutation = false
        }
        CommandFailureErrorRecorder.reset()
        let result: T
        do {
            result = try await runtime.interactionMutationTracker.withPendingDurableMutationVisible(
                createdByCurrentCommand: createdDurableMutation,
                operation: operation
            )
            try Task.checkCancellation()
        } catch {
            _ = await self.invalidateSnapshotsAfterCommandIfNeeded(
                dependencies: dependencies,
                required: required,
                succeeded: false,
                failure: self.underlyingCommandFailure(from: error),
                mutationSequenceAtStart: mutationSequenceAtStart,
                createdDurableMutation: createdDurableMutation
            )
            throw error
        }

        let hadPendingMutation = required && runtime.interactionMutationTracker.mutationStartedAt != nil
        let invalidated = await invalidateSnapshotsAfterCommandIfNeeded(
            dependencies: dependencies,
            required: required,
            succeeded: true,
            mutationSequenceAtStart: mutationSequenceAtStart,
            createdDurableMutation: createdDurableMutation
        )
        do {
            try Task.checkCancellation()
        } catch {
            if hadPendingMutation {
                _ = await self.invalidateSnapshots(
                    dependencies: dependencies,
                    reason: "command cancellation",
                    through: Date(),
                    preserving: nil,
                    preservedAt: nil
                )
            }
            throw error
        }
        if !invalidated {
            fputs("\(CommanderRuntimeExecutorMessage.snapshotInvalidationWarning)\n", stderr)
        }
        return result
    }

    /// Commands report their real error via `handleError` and rethrow the opaque
    /// `ExitCode.failure`; recover the recorded original so the failure can be classified.
    private static func underlyingCommandFailure(from thrown: any Error) -> any Error {
        let recorded = CommandFailureErrorRecorder.consume()
        if thrown is ExitCode {
            return recorded ?? thrown
        }
        return thrown
    }

    static func invalidateSnapshotsAfterCommandIfNeeded(
        dependencies: SnapshotInvalidationDependencies,
        required: Bool,
        succeeded: Bool,
        failure: (any Error)? = nil,
        mutationSequenceAtStart: UInt64,
        createdDurableMutation: Bool
    ) async -> Bool {
        let completion = Date()
        let tracker = dependencies.tracker
        guard required else { return true }
        guard tracker.mutationStartedAt != nil else {
            guard createdDurableMutation else {
                return !tracker.hasPendingDurableMutation
            }
            do {
                try tracker.cancelDurableMutation()
                return true
            } catch {
                return false
            }
        }
        if !succeeded, self.failureBypassesSnapshotInvalidation(
            failure: failure,
            tracker: tracker,
            mutationSequenceAtStart: mutationSequenceAtStart
        ) {
            // The command failed before dispatching any desktop event, so existing snapshots stay
            // valid. Cancel the barrier instead of advancing the watermark and hiding them all.
            guard createdDurableMutation else { return true }
            do {
                try tracker.cancelDurableMutation()
                return true
            } catch {
                dependencies.logger.debug(
                    "Could not cancel the desktop mutation barrier after a pre-dispatch failure: " +
                        error.localizedDescription
                )
                // Fall through to the conservative invalidation below.
            }
        }
        guard let requestedCutoff = tracker.invalidationCutoff(
            commandCompletedAt: completion,
            succeeded: succeeded
        )
        else { return true }
        let durableCompletion: DesktopMutationWatermarkStore.MutationCompletion?
        do {
            if createdDurableMutation,
               tracker.mutationSequence == mutationSequenceAtStart {
                try tracker.cancelDurableMutation()
                durableCompletion = nil
            } else {
                durableCompletion = try tracker.completeDurableMutation(
                    through: succeeded ? requestedCutoff : completion
                )
            }
        } catch {
            tracker.markInvalidationFailed(through: completion)
            return false
        }
        let cutoff = max(requestedCutoff, durableCompletion?.cutoff ?? requestedCutoff)
        let preservationAllowed = durableCompletion?.allowsObservationPreservation ?? true
        let preservedSnapshotID = succeeded && preservationAllowed
            ? tracker.preservedSnapshotID
            : nil
        let preservedAt = preservedSnapshotID == nil
            ? nil
            : tracker.preservedAt
        return await self.invalidateSnapshots(
            dependencies: dependencies,
            reason: "command execution",
            through: cutoff,
            preserving: preservedSnapshotID,
            preservedAt: preservedAt
        )
    }

    /// Whether a failed command is known not to have dispatched any desktop event, so cached
    /// snapshots must stay resolvable. Stays conservative (returns `false`) whenever the command
    /// crossed more than one mutation boundary (an earlier action such as a focus change may have
    /// dispatched), a previous invalidation attempt already failed, or the error class is
    /// ambiguous about whether an event reached the desktop (e.g. timeouts).
    static func failureBypassesSnapshotInvalidation(
        failure: (any Error)?,
        tracker: InteractionMutationTracker,
        mutationSequenceAtStart: UInt64
    ) -> Bool {
        guard let failure else { return false }
        guard !tracker.hasFailedInvalidationAttempt else { return false }
        guard tracker.mutationSequence - mutationSequenceAtStart <= 1 else { return false }
        return self.failureLeavesDesktopUnchanged(failure)
    }

    private static func failureLeavesDesktopUnchanged(_ error: any Error) -> Bool {
        if error is Commander.ValidationError {
            return true
        }
        if let envelope = error as? PeekabooBridgeErrorEnvelope {
            return envelope.failedBeforeDispatchingDesktopEvent
        }
        if let peekabooError = error as? PeekabooError {
            return peekabooError.failedBeforeDispatchingDesktopEvent
        }
        return false
    }

    private static func invalidateSnapshots(
        dependencies: SnapshotInvalidationDependencies,
        reason: String,
        through cutoff: Date,
        preserving preservedSnapshotID: String?,
        preservedAt: Date?
    ) async -> Bool {
        let isRetry = dependencies.tracker.hasFailedInvalidationAttempt
        let invalidated = await InteractionObservationInvalidator.invalidateAfterMutation(
            targets: dependencies.targets,
            logger: dependencies.logger,
            reason: reason,
            through: cutoff,
            preserving: preservedSnapshotID,
            preservedAt: preservedAt
        )
        if invalidated {
            return true
        }
        if isRetry {
            return false
        }
        return await InteractionObservationInvalidator.invalidateAfterMutation(
            targets: dependencies.targets,
            logger: dependencies.logger,
            reason: "\(reason) retry",
            through: cutoff,
            preserving: preservedSnapshotID,
            preservedAt: preservedAt
        )
    }
}
