import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

// MARK: - Service Bridges

enum AutomationServiceBridge {
    static func waitForElement(
        automation: any UIAutomationServiceProtocol,
        target: ClickTarget,
        timeout: TimeInterval,
        snapshotId: String?
    ) async throws -> WaitForElementResult {
        let result = try await Task { @MainActor in
            try await automation.waitForElement(target: target, timeout: timeout, snapshotId: snapshotId)
        }.value

        if !result.warnings.isEmpty {
            Logger.shared.debug(
                "waitForElement warnings: \(result.warnings.joined(separator: ","))",
                category: "Automation"
            )
        }

        return result
    }

    static func click(
        automation: any UIAutomationServiceProtocol,
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            if let automation = automation as? any UIAutomationActionOutcomeProviding {
                return try await automation.clickWithOutcome(
                    target: target,
                    clickType: clickType,
                    snapshotId: snapshotId
                )
            }
            try await automation.click(target: target, clickType: clickType, snapshotId: snapshotId)
            return UIAutomationActionResult(payload: (), outcome: nil)
        }.value
    }

    static func click(
        automation: any UIAutomationServiceProtocol,
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity,
        targetWindowID: Int? = nil,
        expectedWindowIdentity: WindowMutationIdentity? = nil,
        expectedWindowBounds: CGRect? = nil
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            guard let targetedClickService = automation as? any TargetedClickServiceProtocol else {
                throw PeekabooError.serviceUnavailable(
                    "Background clicks require an automation service that supports targeted click delivery"
                )
            }

            guard targetedClickService.supportsTargetedClicks else {
                throw self.targetedClickUnavailableError(service: targetedClickService)
            }
            let allowsAccessibilityValueDelivery =
                targetedClickService.supportsTargetedClickAccessibilityValueDelivery

            if let targetWindowID {
                guard let exactWindowService = targetedClickService as? any ExactWindowTargetedClickServiceProtocol
                else {
                    throw PeekabooError.serviceUnavailable(
                        "Background clicks with an exact window require a compatible automation service"
                    )
                }
                guard let expectedWindowIdentity,
                      let expectedWindowBounds,
                      expectedWindowIdentity.windowID == targetWindowID,
                      expectedWindowIdentity.ownerProcessIdentifier == expectedProcessIdentity.processIdentifier,
                      expectedWindowIdentity.ownerProcessStartIdentity == expectedProcessIdentity.processStartIdentity
                else {
                    throw PeekabooError.invalidInput(
                        field: "target",
                        reason: "Exact-window clicks require a matching process-generation identity and bounds"
                    )
                }
                if let automation = automation as? any UIAutomationActionOutcomeProviding {
                    return try await automation.clickWithOutcome(
                        target: target,
                        clickType: clickType,
                        snapshotId: snapshotId,
                        windowEvidence: ExactWindowClickEvidence(
                            identity: expectedWindowIdentity,
                            bounds: expectedWindowBounds
                        ),
                        allowsAccessibilityValueDelivery: allowsAccessibilityValueDelivery
                    )
                }
                try await exactWindowService.click(
                    target: target,
                    clickType: clickType,
                    snapshotId: snapshotId,
                    windowEvidence: ExactWindowClickEvidence(
                        identity: expectedWindowIdentity,
                        bounds: expectedWindowBounds
                    ),
                    allowsAccessibilityValueDelivery: allowsAccessibilityValueDelivery
                )
            } else {
                guard targetedClickService.supportsProcessGenerationPinnedClicks else {
                    throw PeekabooError.serviceUnavailable(
                        "Background clicks require process-generation-pinned delivery; update the runtime host"
                    )
                }
                if let automation = automation as? any UIAutomationActionOutcomeProviding {
                    return try await automation.clickWithOutcome(
                        target: target,
                        clickType: clickType,
                        snapshotId: snapshotId,
                        expectedProcessIdentity: expectedProcessIdentity,
                        allowsAccessibilityValueDelivery: allowsAccessibilityValueDelivery
                    )
                }
                try await targetedClickService.click(
                    target: target,
                    clickType: clickType,
                    snapshotId: snapshotId,
                    expectedProcessIdentity: expectedProcessIdentity,
                    allowsAccessibilityValueDelivery: allowsAccessibilityValueDelivery
                )
            }
            return UIAutomationActionResult(payload: (), outcome: nil)
        }.value
    }

    static func typeActions(
        automation: any UIAutomationServiceProtocol,
        request: TypeActionsRequest
    ) async throws -> UIAutomationActionResult<TypeResult> {
        try await Task { @MainActor in
            if let automation = automation as? any UIAutomationActionOutcomeProviding {
                return try await automation.typeActionsWithOutcome(
                    request.actions,
                    cadence: request.cadence,
                    snapshotId: request.snapshotId
                )
            }
            let payload = try await automation.typeActions(
                request.actions,
                cadence: request.cadence,
                snapshotId: request.snapshotId
            )
            return UIAutomationActionResult(payload: payload, outcome: nil)
        }.value
    }

    static func typeActions(
        automation: any UIAutomationServiceProtocol,
        request: TypeActionsRequest,
        expectedProcessIdentity: ApplicationProcessIdentity
    ) async throws -> UIAutomationActionResult<TypeResult> {
        try await Task { @MainActor in
            guard let targetedTypeService = automation as? any TargetedTypeServiceProtocol else {
                throw PeekabooError.serviceUnavailable(
                    "Background typing requires an automation service that supports targeted type delivery"
                )
            }

            guard targetedTypeService.supportsTargetedTypeActions,
                  targetedTypeService.supportsProcessGenerationPinnedTypeActions
            else {
                throw self.targetedTypeUnavailableError(service: targetedTypeService)
            }
            if request.actions.contains(where: \.mayUseAccessibilityValueDelivery) {
                try ExactWindowKeyboardRuntime.requireCompositeTypeDelivery(
                    automation: automation,
                    operation: "Background typing"
                )
            }

            if let automation = automation as? any UIAutomationActionOutcomeProviding {
                return try await automation.typeActionsWithOutcome(
                    request.actions,
                    cadence: request.cadence,
                    snapshotId: request.snapshotId,
                    expectedProcessIdentity: expectedProcessIdentity
                )
            }
            let payload = try await targetedTypeService.typeActions(
                request.actions,
                cadence: request.cadence,
                snapshotId: request.snapshotId,
                expectedProcessIdentity: expectedProcessIdentity
            )
            return UIAutomationActionResult(payload: payload, outcome: nil)
        }.value
    }

    static func typeActions(
        automation: any UIAutomationServiceProtocol,
        request: TypeActionsRequest,
        target: UIAutomationTarget
    ) async throws -> UIAutomationActionResult<TypeResult> {
        switch target {
        case .foreground:
            return try await self.typeActions(automation: automation, request: request)
        case let .process(process):
            guard let identity = process.identity else {
                throw PeekabooError.invalidInput(
                    field: "target",
                    reason: "Background typing requires a process-generation receipt"
                )
            }
            return try await self.typeActions(
                automation: automation,
                request: request,
                expectedProcessIdentity: identity
            )
        case let .exactWindow(exactWindow):
            let requiresCompositeTypeDelivery = request.actions.contains(
                where: \.mayUseAccessibilityValueDelivery
            )
            let outcomeService = if requiresCompositeTypeDelivery {
                try ExactWindowKeyboardRuntime.requireTypeOutcomeProvider(
                    automation: automation,
                    operation: "Background typing"
                )
            } else {
                try ExactWindowKeyboardRuntime.requireOutcomeProvider(
                    automation: automation,
                    operation: "Background typing"
                )
            }
            guard let focusedElement = exactWindow.focusedElement else {
                throw PeekabooError.invalidInput(
                    field: "target",
                    reason: "Exact-window typing requires a focused-element receipt"
                )
            }
            return try await ExactWindowKeyboardRuntime.validateRouteReceipt(
                outcomeService.typeActionsWithOutcome(
                    request.actions,
                    cadence: request.cadence,
                    snapshotId: request.snapshotId,
                    target: ExactWindowKeyboardTarget(
                        windowIdentity: exactWindow.identity,
                        windowBounds: exactWindow.bounds,
                        focusedElement: focusedElement
                    )
                ),
                operation: "Background typing",
                allowsCompositeTypeDelivery: requiresCompositeTypeDelivery
            )
        }
    }

    static func scroll(
        automation: any UIAutomationServiceProtocol,
        request: ScrollRequest
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            if let automation = automation as? any UIAutomationActionOutcomeProviding {
                return try await automation.scrollWithOutcome(request)
            }
            try await automation.scroll(request)
            return UIAutomationActionResult(payload: (), outcome: nil)
        }.value
    }

    static func setValue(
        automation: any UIAutomationServiceProtocol,
        target: String,
        value: UIElementValue,
        snapshotId: String?
    ) async throws -> UIAutomationActionResult<ElementActionResult> {
        try await Task { @MainActor in
            guard let automation = automation as? any ElementActionAutomationServiceProtocol else {
                throw PeekabooError.serviceUnavailable(
                    "This automation host does not support direct accessibility value setting"
                )
            }
            guard automation.supportsSetValueResultTargetBinding else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .runtimeIncompatible,
                    message: "The automation host cannot return a verifiable set-value result.",
                    hint: "Update the runtime host before retrying set-value."
                )
            }
            guard automation.supportsProcessGenerationBoundElementMutations else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .runtimeIncompatible,
                    message: "The automation host cannot bind set-value to one process generation.",
                    hint: "Update the runtime host before retrying set-value."
                )
            }
            guard let outcomeAutomation = automation as? any UIAutomationActionOutcomeProviding else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .runtimeIncompatible,
                    message: "The automation host cannot return a receipted set-value outcome.",
                    hint: "Update the runtime host before retrying set-value."
                )
            }
            return try await outcomeAutomation.setValueWithOutcome(
                target: target,
                value: value,
                snapshotId: snapshotId
            )
        }.value
    }

    static func performAction(
        automation: any UIAutomationServiceProtocol,
        target: String,
        actionName: String,
        snapshotId: String?
    ) async throws -> UIAutomationActionResult<ElementActionResult> {
        try await Task { @MainActor in
            guard let automation = automation as? any ElementActionAutomationServiceProtocol else {
                throw PeekabooError.serviceUnavailable(
                    "This automation host does not support direct accessibility action invocation"
                )
            }
            guard automation.supportsProcessGenerationBoundElementMutations else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .runtimeIncompatible,
                    message: "The automation host cannot bind element actions to one process generation.",
                    hint: "Update the runtime host before retrying this element action."
                )
            }
            guard let outcomeAutomation = automation as? any UIAutomationActionOutcomeProviding else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .runtimeIncompatible,
                    message: "The automation host cannot return a receipted action outcome.",
                    hint: "Update the runtime host before retrying this element action."
                )
            }
            return try await outcomeAutomation.performActionWithOutcome(
                target: target,
                actionName: actionName,
                snapshotId: snapshotId
            )
        }.value
    }

    static func hotkey(
        automation: any UIAutomationServiceProtocol,
        keys: String,
        holdDuration: Int
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            if let automation = automation as? any UIAutomationActionOutcomeProviding {
                return try await automation.hotkeyWithOutcome(keys: keys, holdDuration: holdDuration)
            }
            try await automation.hotkey(keys: keys, holdDuration: holdDuration)
            return UIAutomationActionResult(payload: (), outcome: nil)
        }.value
    }

    static func hotkey(
        automation: any UIAutomationServiceProtocol,
        keys: String,
        holdDuration: Int,
        target: UIAutomationTarget
    ) async throws -> UIAutomationActionResult<Void> {
        switch target {
        case .foreground:
            return try await self.hotkey(automation: automation, keys: keys, holdDuration: holdDuration)
        case let .process(process):
            guard let identity = process.identity else {
                throw PeekabooError.invalidInput(
                    field: "target",
                    reason: "Background hotkeys require a process-generation receipt"
                )
            }
            return try await self.hotkey(
                automation: automation,
                keys: keys,
                holdDuration: holdDuration,
                expectedProcessIdentity: identity
            )
        case let .exactWindow(exactWindow):
            let outcomeService = try ExactWindowKeyboardRuntime.requireOutcomeProvider(
                automation: automation,
                operation: "Background hotkeys"
            )
            guard let focusedElement = exactWindow.focusedElement else {
                throw PeekabooError.invalidInput(
                    field: "target",
                    reason: "Exact-window hotkeys require a focused-element receipt"
                )
            }
            return try await ExactWindowKeyboardRuntime.validateRouteReceipt(
                outcomeService.hotkeyWithOutcome(
                    keys: keys,
                    holdDuration: holdDuration,
                    target: ExactWindowKeyboardTarget(
                        windowIdentity: exactWindow.identity,
                        windowBounds: exactWindow.bounds,
                        focusedElement: focusedElement
                    )
                ),
                operation: "Background hotkeys"
            )
        }
    }

    static func hotkey(
        automation: any UIAutomationServiceProtocol,
        keys: String,
        holdDuration: Int,
        targetProcessIdentifier: pid_t
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            try BackgroundHotkeyPolicy.validate(keys: keys)

            guard let targetedHotkeyService = automation as? any TargetedHotkeyServiceProtocol else {
                throw PeekabooError.serviceUnavailable(
                    "Background hotkeys require an automation service that supports targeted hotkey delivery"
                )
            }

            guard targetedHotkeyService.supportsTargetedHotkeys else {
                throw self.targetedHotkeyUnavailableError(service: targetedHotkeyService)
            }

            if let automation = automation as? any UIAutomationActionOutcomeProviding {
                return try await automation.hotkeyWithOutcome(
                    keys: keys,
                    holdDuration: holdDuration,
                    targetProcessIdentifier: targetProcessIdentifier
                )
            }
            try await targetedHotkeyService.hotkey(
                keys: keys,
                holdDuration: holdDuration,
                targetProcessIdentifier: targetProcessIdentifier
            )
            return UIAutomationActionResult(payload: (), outcome: nil)
        }.value
    }

    static func hotkey(
        automation: any UIAutomationServiceProtocol,
        keys: String,
        holdDuration: Int,
        expectedProcessIdentity: ApplicationProcessIdentity
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            try BackgroundHotkeyPolicy.validate(keys: keys)

            guard let targetedHotkeyService = automation as? any TargetedHotkeyServiceProtocol,
                  targetedHotkeyService.supportsProcessGenerationPinnedHotkeys
            else {
                throw PeekabooError.serviceUnavailable(
                    "Background hotkeys require process-generation-pinned delivery; update the runtime host"
                )
            }

            if let automation = automation as? any UIAutomationActionOutcomeProviding {
                return try await automation.hotkeyWithOutcome(
                    keys: keys,
                    holdDuration: holdDuration,
                    expectedProcessIdentity: expectedProcessIdentity
                )
            }
            try await targetedHotkeyService.hotkey(
                keys: keys,
                holdDuration: holdDuration,
                expectedProcessIdentity: expectedProcessIdentity
            )
            return UIAutomationActionResult(payload: (), outcome: nil)
        }.value
    }

    private static func targetedHotkeyUnavailableError(service: any TargetedHotkeyServiceProtocol) -> PeekabooError {
        if service.targetedHotkeyRequiresEventSynthesizingPermission {
            return .permissionDeniedEventSynthesizing
        }

        return .serviceUnavailable(
            service.targetedHotkeyUnavailableReason ??
                "Remote bridge host does not support background hotkeys; use --no-remote or update the host"
        )
    }

    private static func targetedTypeUnavailableError(service: any TargetedTypeServiceProtocol) -> PeekabooError {
        if service.targetedTypeRequiresEventSynthesizingPermission {
            return .permissionDeniedEventSynthesizing
        }

        return .serviceUnavailable(
            service.targetedTypeUnavailableReason ??
                "Remote bridge host does not support background typing; use --no-remote or update the host"
        )
    }

    private static func targetedClickUnavailableError(service: any TargetedClickServiceProtocol) -> PeekabooError {
        if service.targetedClickRequiresEventSynthesizingPermission {
            return .permissionDeniedEventSynthesizing
        }

        return .serviceUnavailable(
            service.targetedClickUnavailableReason ??
                "Remote bridge host does not support background clicks; use --no-remote or update the host"
        )
    }

    static func drag(
        automation: any UIAutomationServiceProtocol,
        request: DragRequest
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            let operation = DragOperationRequest(
                from: request.from,
                to: request.to,
                duration: request.duration,
                steps: request.steps,
                modifiers: request.modifiers,
                button: request.button,
                profile: request.profile
            )
            if let results = automation as? any UIAutomationGlobalPointerActionResultProviding {
                return try await results.dragWithOutcome(operation)
            }
            try await automation.drag(operation)
            return UIAutomationActionResult(payload: (), outcome: nil)
        }.value
    }

    static func moveMouse(
        automation: any UIAutomationServiceProtocol,
        to point: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            if let results = automation as? any UIAutomationGlobalPointerActionResultProviding {
                return try await results.moveMouseWithOutcome(
                    to: point,
                    duration: duration,
                    steps: steps,
                    profile: profile
                )
            }
            try await automation.moveMouse(to: point, duration: duration, steps: steps, profile: profile)
            return UIAutomationActionResult(payload: (), outcome: nil)
        }.value
    }

    /// Preserves an exact setup-focus result without attributing the following shared-pointer
    /// mutation to that window. Current result providers return the leaf's canonical global
    /// outcome; legacy providers intentionally keep their receiptless compatibility behavior.
    static func composeGlobalPointerResult(
        setupFocus: UIAutomationActionResult<Void>,
        pointerAction: UIAutomationActionResult<Void>,
        operation: String,
        route: DesktopActionOutcome.Route
    ) throws -> UIAutomationActionResult<Void> {
        if pointerAction.outcome != nil {
            _ = try validatedSuccessfulActionResult(
                pointerAction,
                operation: operation,
                requiresTarget: false
            )
        }

        let sequence = CommandActionSequenceAccumulator()
        try sequence.record(setupFocus, operation: "\(operation) setup focus")
        try sequence.recordExactTargetLeaf(
            outcome: pointerAction.outcome,
            targetIdentity: nil,
            operation: operation,
            receiptlessStep: .dispatched(
                route: route,
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                unitCount: .one
            )
        )
        return sequence.result(payload: ())
    }

    static func detectElements(
        automation: any UIAutomationServiceProtocol,
        imageData: Data,
        snapshotId: String?,
        windowContext: WindowContext?
    ) async throws -> ElementDetectionResult {
        try await Task { @MainActor in
            try await automation.detectElements(
                in: imageData,
                snapshotId: snapshotId,
                windowContext: windowContext
            )
        }.value
    }

    static func hasAccessibilityPermission(automation: any UIAutomationServiceProtocol) async -> Bool {
        await Task { @MainActor in
            await automation.hasAccessibilityPermission()
        }.value
    }
}

struct TypeActionsRequest {
    let actions: [TypeAction]
    let cadence: TypingCadence
    let snapshotId: String?
}

struct DragRequest {
    let from: CGPoint
    let to: CGPoint
    let duration: Int
    let steps: Int
    let modifiers: String?
    let button: DragButton
    let profile: MouseMovementProfile
}

enum ApplicationServiceBridge {
    static func launchApplication(
        applications: any ApplicationServiceProtocol,
        request: ApplicationLaunchRequest
    ) async throws -> DesktopActionResult<ServiceApplicationInfo> {
        try await self.perform {
            let result = try await applications.launchApplicationResult(request: request)
            try ApplicationActionResultSemantics.requireSuccessfulOutcome(
                result.outcome,
                operation: "Application launch"
            )
            return result
        }
    }

    static func relaunchApplication(
        applications: any ApplicationServiceProtocol,
        request: ApplicationRelaunchRequest
    ) async throws -> DesktopActionResult<ServiceApplicationInfo> {
        try await self.perform {
            let result = try await applications.relaunchApplicationResult(request: request)
            try ApplicationActionResultSemantics.requireSuccessfulOutcome(
                result.outcome,
                operation: "Application relaunch"
            )
            return result
        }
    }

    static func activateApplication(
        applications: any ApplicationServiceProtocol,
        request: ApplicationActivationRequest
    ) async throws -> DesktopActionResult<Void> {
        try await self.perform {
            let result = try await applications.activateApplicationResult(request: request)
            try ApplicationActionResultSemantics.requireSuccessfulOutcome(
                result.outcome,
                operation: "Application activation"
            )
            return result
        }
    }

    static func activateApplicationTargeted(
        applications: any ApplicationServiceProtocol,
        application: ServiceApplicationInfo
    ) async throws -> UIAutomationActionResult<Void> {
        try await self.perform {
            guard let expectedIdentity = application.processIdentity else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Application discovery did not return a process-generation identity for exact activation.",
                    hint: "Refresh the application inventory before retrying."
                )
            }
            let result = try await applications.activateApplicationTargetedResult(
                request: ApplicationActivationRequest(application: application)
            )
            try ApplicationActionResultSemantics.requireSuccessfulExactProcessResult(
                result,
                expectedIdentity: expectedIdentity,
                operation: "Application activation"
            )
            return result
        }
    }

    static func quitApplication(
        applications: any ApplicationServiceProtocol,
        request: ApplicationQuitRequest
    ) async throws -> DesktopActionResult<Bool> {
        try await self.perform {
            guard let expectedIdentity = request.expectedIdentity else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .invalidRequest,
                    message: "Application quit requires a process-generation identity.",
                    hint: "Refresh the application inventory before retrying."
                )
            }
            let result = try await applications.quitApplicationResult(request: request)
            try ApplicationActionResultSemantics.requireConsistentQuitResult(
                result,
                expectedIdentity: expectedIdentity,
                operation: "Application quit"
            )
            return result
        }
    }

    static func hideApplication(
        applications: any ApplicationServiceProtocol,
        application: ServiceApplicationInfo
    ) async throws -> UIAutomationActionResult<Void> {
        try await self.perform {
            guard let expectedIdentity = application.processIdentity else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Application discovery did not return a process-generation identity for exact hide.",
                    hint: "Refresh the application inventory before retrying."
                )
            }
            let result = try await applications.hideApplicationTargetedResult(request: .init(
                identifier: "PID:\(expectedIdentity.processIdentifier)",
                expectedIdentity: expectedIdentity
            ))
            try ApplicationActionResultSemantics.requireSuccessfulExactProcessResult(
                result,
                expectedIdentity: expectedIdentity,
                operation: "Application hide"
            )
            return result
        }
    }

    private static func perform<Result: Sendable>(
        _ body: @MainActor @Sendable () async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        return try await self.performOnMainActor(body)
    }

    @MainActor
    private static func performOnMainActor<Result: Sendable>(
        _ body: @MainActor @Sendable () async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        return try await body()
    }
}

enum WindowServiceBridge {
    @discardableResult
    static func closeWindow(
        windows: any WindowManagementServiceProtocol,
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity? = nil,
        allowForegroundFallback: Bool = false
    ) async throws -> UIAutomationActionResult<Void> {
        let operation = Task { @MainActor in
            if let expectedIdentity {
                try windows.requireWindowMutationResultProvider(operation: "Window close")
                let result = try await windows.closeWindowResult(
                    target: target,
                    expectedIdentity: expectedIdentity,
                    allowForegroundFallback: allowForegroundFallback
                )
                return try windows.validatedWindowMutationResult(
                    result,
                    expectedIdentity: expectedIdentity,
                    operation: "Window close"
                )
            }
            try await windows.closeWindow(
                target: target,
                allowForegroundFallback: allowForegroundFallback
            )
            return UIAutomationActionResult(payload: (), outcome: nil)
        }

        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    @discardableResult
    static func minimizeWindow(
        windows: any WindowManagementServiceProtocol,
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity? = nil
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            if let expectedIdentity {
                try windows.requireWindowMutationResultProvider(operation: "Window minimize")
                let result = try await windows.minimizeWindowResult(
                    target: target,
                    expectedIdentity: expectedIdentity
                )
                return try windows.validatedWindowMutationResult(
                    result,
                    expectedIdentity: expectedIdentity,
                    operation: "Window minimize"
                )
            }
            try await windows.minimizeWindow(target: target)
            return UIAutomationActionResult(payload: (), outcome: nil)
        }.value
    }

    @discardableResult
    static func restoreWindow(
        windows: any WindowManagementServiceProtocol,
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity? = nil
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            if let expectedIdentity {
                try windows.requireWindowMutationResultProvider(operation: "Window restore")
                let result = try await windows.restoreWindowResult(
                    target: target,
                    expectedIdentity: expectedIdentity
                )
                return try windows.validatedWindowMutationResult(
                    result,
                    expectedIdentity: expectedIdentity,
                    operation: "Window restore"
                )
            }
            try await windows.restoreWindow(target: target)
            return UIAutomationActionResult(payload: (), outcome: nil)
        }.value
    }

    @discardableResult
    static func maximizeWindow(
        windows: any WindowManagementServiceProtocol,
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity? = nil
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            if let expectedIdentity {
                try windows.requireWindowMutationResultProvider(operation: "Window maximize")
                let result = try await windows.maximizeWindowResult(
                    target: target,
                    expectedIdentity: expectedIdentity
                )
                return try windows.validatedWindowMutationResult(
                    result,
                    expectedIdentity: expectedIdentity,
                    operation: "Window maximize"
                )
            }
            try await windows.maximizeWindow(target: target)
            return UIAutomationActionResult(payload: (), outcome: nil)
        }.value
    }

    @discardableResult
    static func moveWindow(
        windows: any WindowManagementServiceProtocol,
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity? = nil,
        to origin: CGPoint
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            if let expectedIdentity {
                try windows.requireWindowMutationResultProvider(operation: "Window move")
                let result = try await windows.moveWindowResult(
                    target: target,
                    expectedIdentity: expectedIdentity,
                    to: origin
                )
                return try windows.validatedWindowMutationResult(
                    result,
                    expectedIdentity: expectedIdentity,
                    operation: "Window move"
                )
            }
            try await windows.moveWindow(target: target, to: origin)
            return UIAutomationActionResult(payload: (), outcome: nil)
        }.value
    }

    @discardableResult
    static func resizeWindow(
        windows: any WindowManagementServiceProtocol,
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity? = nil,
        to size: CGSize
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            if let expectedIdentity {
                try windows.requireWindowMutationResultProvider(operation: "Window resize")
                let result = try await windows.resizeWindowResult(
                    target: target,
                    expectedIdentity: expectedIdentity,
                    to: size
                )
                return try windows.validatedWindowMutationResult(
                    result,
                    expectedIdentity: expectedIdentity,
                    operation: "Window resize"
                )
            }
            try await windows.resizeWindow(target: target, to: size)
            return UIAutomationActionResult(payload: (), outcome: nil)
        }.value
    }

    @discardableResult
    static func setWindowBounds(
        windows: any WindowManagementServiceProtocol,
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity? = nil,
        bounds: CGRect
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            if let expectedIdentity {
                try windows.requireWindowMutationResultProvider(operation: "Window set bounds")
                let result = try await windows.setWindowBoundsResult(
                    target: target,
                    expectedIdentity: expectedIdentity,
                    bounds: bounds
                )
                return try windows.validatedWindowMutationResult(
                    result,
                    expectedIdentity: expectedIdentity,
                    operation: "Window set bounds"
                )
            }
            try await windows.setWindowBounds(target: target, bounds: bounds)
            return UIAutomationActionResult(payload: (), outcome: nil)
        }.value
    }

    static func focusWindow(
        windows: any WindowManagementServiceProtocol,
        target: WindowTarget
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            try await windows.focusWindowResult(target: target)
        }.value
    }

    static func focusWindow(
        windows: any WindowManagementServiceProtocol,
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            let result = try await windows.focusWindowResult(
                target: target,
                expectedIdentity: expectedIdentity
            )
            return try windows.validatedWindowMutationResult(
                result,
                expectedIdentity: expectedIdentity,
                operation: "Window focus"
            )
        }.value
    }

    static func listWindows(
        windows: any WindowManagementServiceProtocol,
        target: WindowTarget
    ) async throws -> [ServiceWindowInfo] {
        try await Task { @MainActor in
            try await windows.listWindows(target: target)
        }.value
    }

    static func mutationInventory(
        windows: any WindowManagementServiceProtocol,
        target: WindowTarget
    ) async throws -> DesktopTargetPlanning.Inventory<ServiceWindowInfo> {
        try await Task { @MainActor in
            try await windows.mutationInventory(target: target)
        }.value
    }

    static func getFocusedWindow(windows: any WindowManagementServiceProtocol) async throws -> ServiceWindowInfo? {
        try await Task { @MainActor in
            try await windows.getFocusedWindow()
        }.value
    }
}

enum MenuServiceBridge {
    static func listMenus(menu: any MenuServiceProtocol, appIdentifier: String) async throws -> MenuStructure {
        try await Task { @MainActor in
            try await menu.listMenus(for: appIdentifier)
        }.value
    }

    static func listMenus(
        menu: any MenuServiceProtocol,
        request: MenuListRequest
    ) async throws -> MenuStructure {
        try await Task { @MainActor in
            try await menu.listMenus(request: request)
        }.value
    }

    static func clickMenuItem(
        menu: any MenuServiceProtocol,
        request: MenuItemActionRequest
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            guard let menu = menu as? any MenuServiceGenerationPinnedActionResultProviding else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .runtimeIncompatible,
                    message: "Exact menu click requires a generation-pinned result provider.",
                    hint: "Update the selected Peekaboo runtime before retrying."
                )
            }
            let result = try await menu.clickMenuItemActionResult(request: request)
            return try menu.validatedGenerationPinnedMenuResult(
                result,
                expectedIdentity: request.expectedIdentity,
                operation: "Menu click"
            )
        }.value
    }

    static func clickMenuItemByName(
        menu: any MenuServiceProtocol,
        request: MenuItemByNameActionRequest
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            guard let menu = menu as? any MenuServiceGenerationPinnedActionResultProviding else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .runtimeIncompatible,
                    message: "Exact named menu click requires a generation-pinned result provider.",
                    hint: "Update the selected Peekaboo runtime before retrying."
                )
            }
            let result = try await menu.clickMenuItemByNameActionResult(request: request)
            return try menu.validatedGenerationPinnedMenuResult(
                result,
                expectedIdentity: request.expectedIdentity,
                operation: "Named menu click"
            )
        }.value
    }

    static func isMenuExtraMenuOpen(
        menu: any MenuServiceProtocol,
        title: String,
        ownerPID: pid_t?
    ) async throws -> Bool {
        try await Task { @MainActor in
            try await menu.isMenuExtraMenuOpen(title: title, ownerPID: ownerPID)
        }.value
    }

    static func listMenuBarItems(menu: any MenuServiceProtocol, includeRaw: Bool = false) async throws
    -> [MenuBarItemInfo] {
        try await Task { @MainActor in
            try await menu.listMenuBarItems(includeRaw: includeRaw)
        }.value
    }

    static func clickMenuBarItem(
        named name: String,
        menu: any MenuServiceProtocol
    ) async throws -> UIAutomationActionResult<PeekabooCore.ClickResult> {
        try await Task<UIAutomationActionResult<PeekabooCore.ClickResult>, any Error> { @MainActor in
            try await menu.clickMenuBarItemResult(named: name)
        }.value
    }

    static func clickMenuBarItem(
        at index: Int,
        menu: any MenuServiceProtocol
    ) async throws -> UIAutomationActionResult<PeekabooCore.ClickResult> {
        try await Task<UIAutomationActionResult<PeekabooCore.ClickResult>, any Error> { @MainActor in
            try await menu.clickMenuBarItemResult(at: index)
        }.value
    }

    static func clickMenuBarItem(
        request: MenuBarItemActionRequest,
        menu: any MenuServiceProtocol
    ) async throws -> UIAutomationActionResult<PeekabooCore.ClickResult> {
        try await Task<UIAutomationActionResult<PeekabooCore.ClickResult>, any Error> { @MainActor in
            try await menu.clickMenuBarItemResult(request: request)
        }.value
    }
}

enum DockServiceBridge {
    static func launchFromDock(
        dock: any DockServiceProtocol,
        appName: String
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            try await dock.launchFromDockResult(appName: appName)
        }.value
    }

    static func findDockItem(dock: any DockServiceProtocol, name: String) async throws -> DockItem {
        try await Task { @MainActor in
            try await dock.findDockItem(name: name)
        }.value
    }

    static func rightClickDockItem(
        dock: any DockServiceProtocol,
        appName: String,
        menuItem: String?
    ) async throws -> UIAutomationActionResult<Void> {
        try await Task { @MainActor in
            try await dock.rightClickDockItemResult(appName: appName, menuItem: menuItem)
        }.value
    }

    static func hideDock(dock: any DockServiceProtocol) async throws -> DesktopActionResult<Void> {
        try await Task { @MainActor in
            try await dock.hideDockResult()
        }.value
    }

    static func showDock(dock: any DockServiceProtocol) async throws -> DesktopActionResult<Void> {
        try await Task { @MainActor in
            try await dock.showDockResult()
        }.value
    }

    static func listDockItems(dock: any DockServiceProtocol, includeAll: Bool) async throws -> [DockItem] {
        try await Task { @MainActor in
            try await dock.listDockItems(includeAll: includeAll)
        }.value
    }
}
