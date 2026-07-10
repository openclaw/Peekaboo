import Commander
import Foundation
import PeekabooAutomationKit

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

    static func runWithImplicitSnapshotInvalidation<T>(
        using runtime: CommandRuntime,
        required: Bool,
        requiresCallerBarrier: Bool = false,
        operation: () async throws -> T
    ) async throws -> T {
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
        let result: T
        do {
            result = try await runtime.interactionMutationTracker.withPendingDurableMutationVisible(
                createdByCurrentCommand: createdDurableMutation,
                operation: operation
            )
            try Task.checkCancellation()
        } catch {
            _ = await self.invalidateSnapshotsAfterCommandIfNeeded(
                using: runtime,
                required: required,
                succeeded: false,
                mutationSequenceAtStart: mutationSequenceAtStart,
                createdDurableMutation: createdDurableMutation
            )
            throw error
        }

        let hadPendingMutation = required && runtime.interactionMutationTracker.mutationStartedAt != nil
        let invalidated = await invalidateSnapshotsAfterCommandIfNeeded(
            using: runtime,
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
                    using: runtime,
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

    private static func invalidateSnapshotsAfterCommandIfNeeded(
        using runtime: CommandRuntime,
        required: Bool,
        succeeded: Bool,
        mutationSequenceAtStart: UInt64,
        createdDurableMutation: Bool
    ) async -> Bool {
        let completion = Date()
        guard required else { return true }
        guard runtime.interactionMutationTracker.mutationStartedAt != nil else {
            guard createdDurableMutation else {
                return !runtime.interactionMutationTracker.hasPendingDurableMutation
            }
            do {
                try runtime.interactionMutationTracker.cancelDurableMutation()
                return true
            } catch {
                return false
            }
        }
        guard let requestedCutoff = runtime.interactionMutationTracker.invalidationCutoff(
            commandCompletedAt: completion,
            succeeded: succeeded
        )
        else { return true }
        let durableCompletion: DesktopMutationWatermarkStore.MutationCompletion?
        do {
            if createdDurableMutation,
               runtime.interactionMutationTracker.mutationSequence == mutationSequenceAtStart {
                try runtime.interactionMutationTracker.cancelDurableMutation()
                durableCompletion = nil
            } else {
                durableCompletion = try runtime.interactionMutationTracker.completeDurableMutation(
                    through: succeeded ? requestedCutoff : completion
                )
            }
        } catch {
            runtime.interactionMutationTracker.markInvalidationFailed(through: completion)
            return false
        }
        let cutoff = max(requestedCutoff, durableCompletion?.cutoff ?? requestedCutoff)
        let preservationAllowed = durableCompletion?.allowsObservationPreservation ?? true
        let preservedSnapshotID = succeeded && preservationAllowed
            ? runtime.interactionMutationTracker.preservedSnapshotID
            : nil
        let preservedAt = preservedSnapshotID == nil
            ? nil
            : runtime.interactionMutationTracker.preservedAt
        return await self.invalidateSnapshots(
            using: runtime,
            reason: "command execution",
            through: cutoff,
            preserving: preservedSnapshotID,
            preservedAt: preservedAt
        )
    }

    private static func invalidateSnapshots(
        using runtime: CommandRuntime,
        reason: String,
        through cutoff: Date,
        preserving preservedSnapshotID: String?,
        preservedAt: Date?
    ) async -> Bool {
        let targets = runtime.interactionMutationTargets
        let isRetry = runtime.interactionMutationTracker.hasFailedInvalidationAttempt
        let invalidated = await InteractionObservationInvalidator.invalidateAfterMutation(
            targets: targets,
            logger: runtime.logger,
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
            targets: targets,
            logger: runtime.logger,
            reason: "\(reason) retry",
            through: cutoff,
            preserving: preservedSnapshotID,
            preservedAt: preservedAt
        )
    }
}
