import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

extension PeekabooBridgeClient {
    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?) async throws -> UIAutomationActionResult<Void>
    {
        try await self.actionResult(
            for: .click(.init(target: target, clickType: clickType, snapshotId: snapshotId)),
            expectedResponse: "click")
        { response in
            guard case .ok = response else { return nil }
            return ()
        }
    }

    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws -> UIAutomationActionResult<Void>
    {
        if let expectedIdentity = Self.currentProcessIdentity(targetProcessIdentifier) {
            return try await self.clickWithOutcome(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                expectedProcessIdentity: expectedIdentity)
        }
        return try await self.actionResult(
            for: .targetedClick(.init(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                targetProcessIdentifier: Int32(targetProcessIdentifier))),
            expectedResponse: "targeted click")
        { response in
            guard case .ok = response else { return nil }
            return ()
        }
    }

    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<Void>
    {
        try await self.actionResult(
            for: .targetedClick(.init(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                targetProcessIdentifier: expectedProcessIdentity.processIdentifier,
                expectedProcessIdentity: expectedProcessIdentity)),
            expectedResponse: "generation-pinned click")
        { response in
            guard case .ok = response else { return nil }
            return ()
        }
    }

    public func clickWithOutcome(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<Void>
    {
        try await self.actionResult(
            for: .targetedClick(.init(
                target: target,
                clickType: clickType,
                snapshotId: snapshotId,
                targetProcessIdentifier: expectedWindowIdentity.ownerProcessIdentifier,
                targetWindowID: expectedWindowIdentity.windowID,
                expectedWindowIdentity: expectedWindowIdentity,
                expectedWindowBounds: expectedWindowBounds)),
            expectedResponse: "exact-window click")
        { response in
            guard case .ok = response else { return nil }
            return ()
        }
    }

    public func typeWithOutcome(
        text: String,
        target: String?,
        clearExisting: Bool,
        typingDelay: Int,
        snapshotId: String?) async throws -> UIAutomationActionResult<Void>
    {
        try await self.actionResult(
            for: .type(.init(
                text: text,
                target: target,
                clearExisting: clearExisting,
                typingDelay: typingDelay,
                snapshotId: snapshotId)),
            expectedResponse: "type")
        { response in
            guard case .ok = response else { return nil }
            return ()
        }
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?) async throws -> UIAutomationActionResult<TypeResult>
    {
        try await self.typeActionResult(for: .typeActions(.init(
            actions: actions,
            cadence: cadence,
            snapshotId: snapshotId)))
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws -> UIAutomationActionResult<TypeResult>
    {
        if let expectedIdentity = Self.currentProcessIdentity(targetProcessIdentifier) {
            return try await self.typeActionsWithOutcome(
                actions,
                cadence: cadence,
                snapshotId: snapshotId,
                expectedProcessIdentity: expectedIdentity)
        }
        return try await self.typeActionResult(for: .targetedTypeActions(.init(
            actions: actions,
            cadence: cadence,
            snapshotId: snapshotId,
            targetProcessIdentifier: Int32(targetProcessIdentifier))))
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<TypeResult>
    {
        try await self.typeActionResult(for: .targetedTypeActions(.init(
            actions: actions,
            cadence: cadence,
            snapshotId: snapshotId,
            targetProcessIdentifier: expectedProcessIdentity.processIdentifier,
            expectedProcessIdentity: expectedProcessIdentity)))
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<TypeResult>
    {
        try await self.typeActionResult(for: .exactWindowTargetedTypeActions(.init(
            actions: actions,
            cadence: cadence,
            snapshotId: snapshotId,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds,
            expectedFocusedElement: nil)))
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        target: ExactWindowKeyboardTarget) async throws -> UIAutomationActionResult<TypeResult>
    {
        try await self.typeActionResult(for: .exactWindowTargetedTypeActions(.init(
            actions: actions,
            cadence: cadence,
            snapshotId: snapshotId,
            expectedWindowIdentity: target.windowIdentity,
            expectedWindowBounds: target.windowBounds,
            expectedFocusedElement: target.focusedElement)))
    }

    public func scrollWithOutcome(
        _ request: ScrollRequest) async throws -> UIAutomationActionResult<Void>
    {
        let payload = PeekabooBridgeScrollRequest(request: request)
        return try await self.actionResult(
            for: request.foreground ? .scroll(payload) : .targetedScroll(payload),
            expectedResponse: "scroll")
        { response in
            guard case .ok = response else { return nil }
            return ()
        }
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int) async throws -> UIAutomationActionResult<Void>
    {
        try await self.voidActionResult(
            for: .hotkey(.init(keys: keys, holdDuration: holdDuration)),
            expectedResponse: "hotkey")
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        targetProcessIdentifier: pid_t) async throws -> UIAutomationActionResult<Void>
    {
        if let expectedIdentity = Self.currentProcessIdentity(targetProcessIdentifier) {
            return try await self.hotkeyWithOutcome(
                keys: keys,
                holdDuration: holdDuration,
                expectedProcessIdentity: expectedIdentity)
        }
        return try await self.voidActionResult(
            for: .targetedHotkey(.init(
                keys: keys,
                holdDuration: holdDuration,
                targetProcessIdentifier: Int32(targetProcessIdentifier))),
            expectedResponse: "targeted hotkey")
    }

    nonisolated static func currentProcessIdentity(
        _ processIdentifier: pid_t) -> ApplicationProcessIdentity?
    {
        SystemIdentityResolver.processStartIdentity(processIdentifier).map {
            ApplicationProcessIdentity(
                processIdentifier: processIdentifier,
                processStartIdentity: $0)
        }
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<Void>
    {
        try await self.voidActionResult(
            for: .targetedHotkey(.init(
                keys: keys,
                holdDuration: holdDuration,
                targetProcessIdentifier: expectedProcessIdentity.processIdentifier,
                expectedProcessIdentity: expectedProcessIdentity)),
            expectedResponse: "generation-pinned hotkey")
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<Void>
    {
        try await self.voidActionResult(
            for: .exactWindowTargetedHotkey(.init(
                keys: keys,
                holdDuration: holdDuration,
                expectedWindowIdentity: expectedWindowIdentity,
                expectedWindowBounds: expectedWindowBounds,
                expectedFocusedElement: nil)),
            expectedResponse: "exact-window hotkey")
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        target: ExactWindowKeyboardTarget) async throws -> UIAutomationActionResult<Void>
    {
        try await self.voidActionResult(
            for: .exactWindowTargetedHotkey(.init(
                keys: keys,
                holdDuration: holdDuration,
                expectedWindowIdentity: target.windowIdentity,
                expectedWindowBounds: target.windowBounds,
                expectedFocusedElement: target.focusedElement)),
            expectedResponse: "focused exact-window hotkey")
    }

    public func setValueWithOutcome(
        target: String,
        value: UIElementValue,
        snapshotId: String?) async throws -> UIAutomationActionResult<ElementActionResult>
    {
        try await self.actionResult(
            for: .setValue(.init(target: target, value: value, snapshotId: snapshotId)),
            expectedResponse: "setValue")
        { response in
            guard case let .elementActionResult(result) = response else { return nil }
            return result
        }
    }

    public func performActionWithOutcome(
        target: String,
        actionName: String,
        snapshotId: String?) async throws -> UIAutomationActionResult<ElementActionResult>
    {
        try await self.actionResult(
            for: .performAction(.init(target: target, actionName: actionName, snapshotId: snapshotId)),
            expectedResponse: "performAction")
        { response in
            guard case let .elementActionResult(result) = response else { return nil }
            return result
        }
    }

    private func typeActionResult(
        for request: PeekabooBridgeRequest) async throws -> UIAutomationActionResult<TypeResult>
    {
        try await self.actionResult(for: request, expectedResponse: "type actions") { response in
            guard case let .typeResult(result) = response else { return nil }
            return result
        }
    }

    private func voidActionResult(
        for request: PeekabooBridgeRequest,
        expectedResponse: String) async throws -> UIAutomationActionResult<Void>
    {
        try await self.actionResult(for: request, expectedResponse: expectedResponse) { response in
            guard case .ok = response else { return nil }
            return ()
        }
    }

    func actionResult<Payload: Sendable>(
        for request: PeekabooBridgeRequest,
        expectedResponse: String,
        requiresTargetIdentity: Bool = false,
        timeoutSec: TimeInterval? = nil,
        operationReceiptRequirement: PeekabooBridgeOperationReceiptRequirement = .whenAvailable,
        extract: (PeekabooBridgeResponse) -> Payload?) async throws -> UIAutomationActionResult<Payload>
    {
        try await self.actionResultWithTransportProvenance(
            for: request,
            expectedResponse: expectedResponse,
            requiresTargetIdentity: requiresTargetIdentity,
            timeoutSec: timeoutSec,
            operationReceiptRequirement: operationReceiptRequirement,
            extract: extract).result
    }

    func actionResultWithTransportProvenance<Payload: Sendable>(
        for request: PeekabooBridgeRequest,
        expectedResponse: String,
        requiresTargetIdentity: Bool = false,
        timeoutSec: TimeInterval? = nil,
        operationReceiptRequirement: PeekabooBridgeOperationReceiptRequirement = .whenAvailable,
        extract: (PeekabooBridgeResponse) -> Payload?) async throws
        -> PeekabooBridgeActionResultWithTransportProvenance<Payload>
    {
        if requiresTargetIdentity, self.usesExplicitReceiptlessTransport() {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "\(expectedResponse) requires an attested exact-target result.",
                hint: "Update the Bridge host to protocol 1.29 before retrying this mutation.")
        }
        let reply = try await self.sendCarryingActionOutcome(
            request,
            timeoutSec: timeoutSec,
            operationReceiptRequirement: operationReceiptRequirement)
        if case let .error(envelope) = reply.response {
            try Self.throwActionFailureOrEnvelope(envelope)
        }
        guard let payload = extract(reply.response) else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected \(expectedResponse) response")
        }
        if requiresTargetIdentity, reply.targetIdentity == nil {
            throw DesktopActionFailure.indeterminate(
                route: reply.outcome?.outcome.route ?? .bridge,
                delivery: reply.outcome?.outcome.delivery,
                evidence: .completionUnknown,
                unitCount: reply.outcome?.outcome.dispatchState.unitCount,
                message: "\(expectedResponse) returned without its attested exact target.",
                hint: "Observe the target before retrying and update the Bridge host.")
        }
        return PeekabooBridgeActionResultWithTransportProvenance(
            result: UIAutomationActionResult(
                payload: payload,
                outcome: reply.outcome?.outcome,
                targetIdentity: reply.targetIdentity,
                selectedLeafEvidence: reply.selectedLeafEvidence),
            hasVerifiedOperationReceipt: reply.hasVerifiedOperationReceipt)
    }
}

struct PeekabooBridgeActionResultWithTransportProvenance<Payload: Sendable>: Sendable {
    let result: UIAutomationActionResult<Payload>
    let hasVerifiedOperationReceipt: Bool
}
