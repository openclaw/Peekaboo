import CoreGraphics
import PeekabooFoundation

/// Runs only inside HotkeyService's existing process lane, after synthesis has been selected.
@MainActor
enum BackgroundWindowKeyboardPreparation {
    static func perform(
        target: UIAutomationTarget.ExactWindow,
        validateOwnership: @escaping @MainActor () throws -> Void) async throws -> DesktopActionOutcome
    {
        guard let expected = target.focusedElement else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest, message: "Background keyboard preparation requires an exact editor receipt.")
        }
        try validateOwnership()
        let admission = try await Self.read(target: target) {
            try (
                BackgroundWindowChromeReader.read(target: target),
                BackgroundKeyboardReceiverState.read(expected: expected))
        }
        let validateAdmission: @MainActor () async throws -> Void = {
            try validateOwnership()
            _ = try await Self.read(target: target) {
                try (
                    BackgroundWindowChromeReader.read(target: target, retained: admission.0),
                    BackgroundKeyboardReceiverState.read(expected: expected, retained: admission.1))
            }
            try validateOwnership()
        }
        return try await self.sequence(
            activation: {
                try await validateAdmission()
                return try BackgroundWindowActivationDriver.prepare(target)
            },
            pointer: {
                try await validateAdmission()
                return try await WindowRoutedPointerDriver().click(
                    at: admission.0.point, button: .left, count: 1,
                    targetProcessIdentifier: target.identity.ownerProcessIdentifier,
                    targetWindowID: CGWindowID(target.identity.windowID),
                    expectedWindowIdentity: target.identity, expectedWindowBounds: target.bounds,
                    beforeButtonDown: validateAdmission)
            },
            postvalidate: {
                try validateOwnership()
                _ = try await Self.read(target: target) {
                    try BackgroundKeyboardReceiverState.read(expected: expected, retained: admission.1)
                }
                try validateOwnership()
            })
    }

    static func sequence(
        activation: () async throws -> DesktopActionOutcome,
        pointer: () async throws -> DesktopActionOutcome,
        postvalidate: () async throws -> Void) async throws -> DesktopActionOutcome
    {
        var sequence = DesktopActionSequenceAccumulator()
        var leafDelivery = DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: .background)
        do {
            try await sequence.record(.outcome(activation()))
            leafDelivery = .init(mechanism: .windowTargetedEvents, mode: .background)
            try await sequence.record(.outcome(pointer()))
            try await postvalidate()
            guard let outcome = sequence.successResolution().outcome else {
                throw PeekabooError.operationError(message: "Background preparation did not report composable outcomes")
            }
            return outcome
        } catch {
            let failure = Self.leafFailure(error, delivery: leafDelivery)
            throw sequence.failure(
                combining: failure,
                message: "Background keyboard preparation did not finish; observe before another input.")
        }
    }

    static func leafFailure(_ error: any Error, delivery: DesktopActionOutcome.Delivery) -> DesktopActionFailure {
        if let failure = error as? DesktopActionFailure {
            return failure
        }
        if let indeterminate = error as? InputDeliveryIndeterminateError {
            return indeterminate.desktopActionFailure(delivery: delivery)
        }
        return .preDispatchRefusal(
            reason: error is CancellationError ? .requestCancelled : .targetUnavailable,
            message: error.localizedDescription)
    }

    static func read<Value: Sendable>(
        target: UIAutomationTarget.ExactWindow,
        operation: @escaping @Sendable () throws -> Value) async throws -> Value
    {
        do {
            return try await ElementDetectionTimeoutRunner.runDetached(
                targetProcessIdentifier: target.identity.ownerProcessIdentifier,
                targetProcessStartIdentity: target.identity.ownerProcessStartIdentity,
                seconds: 0.5,
                operation: operation)
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch {
            // This worker only observes; the sequence separately retains any earlier preparation effects.
            throw DesktopActionFailure.preDispatchRefusal(
                reason: error is CancellationError ? .requestCancelled : .targetUnavailable,
                message: "The exact background window and focused editor could not be observed unchanged.",
                hint: "Observe the target again; this observation did not dispatch preparation input.",
                causeDescription: error.localizedDescription)
        }
    }
}
