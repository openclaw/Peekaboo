import Foundation
import PeekabooFoundation

private typealias ResolvedElementMutationTarget = (
    element: AutomationElement,
    description: String,
    bundleIdentifier: String?,
    windowContext: WindowContext?)

extension UIAutomationService: ElementActionAutomationServiceProtocol {
    public func setValue(
        target: String,
        value: UIElementValue,
        snapshotId: String?) async throws -> ElementActionResult
    {
        try await self.setValueWithOutcome(
            target: target,
            value: value,
            snapshotId: snapshotId).payload
    }

    public func setValueWithOutcome(
        target: String,
        value: UIElementValue,
        snapshotId: String?) async throws -> UIAutomationActionResult<ElementActionResult>
    {
        let requiredSnapshotId = try Self.requireElementActionSnapshotID(snapshotId)
        let captureReceipt = try await self.elementMutationCaptureReceipt(snapshotId: requiredSnapshotId)
        var resolved: ResolvedElementMutationTarget?
        var oldValue: String?
        var newValue: String?
        let plan = try DesktopOperationPlan(
            verb: .setValue,
            selector: .element(target),
            captureReceipt: captureReceipt,
            strategy: self.inputPolicy.strategy(
                for: .setValue,
                bundleIdentifier: captureReceipt.bundleIdentifier),
            prepare: {
                let target = try await self.resolveActionTarget(target, snapshotId: requiredSnapshotId)
                try self.validateElementMutationTarget(target.windowContext, receipt: captureReceipt)
                resolved = target
                oldValue = self.elementMutationValueReader(target.element)
            },
            routing: {
                let bundleIdentifier = resolved?.bundleIdentifier ?? captureReceipt.bundleIdentifier
                return DesktopOperationPlan.Routing(
                    strategy: self.inputPolicy.strategy(for: .setValue, bundleIdentifier: bundleIdentifier),
                    bundleIdentifier: bundleIdentifier)
            },
            action: DesktopOperationPlan.ActionRoute {
                guard let resolved else {
                    throw PeekabooError.operationError(message: "Element mutation target was not prepared")
                }
                do {
                    return try self.actionInputDriver.trySetValue(element: resolved.element, value: value)
                } catch let error as ActionInputError where error.isUnsupportedValueMutation {
                    throw PeekabooError.invalidInput(Self.unsupportedSetValueMessage(
                        target: resolved.description,
                        reason: error.localizedDescription))
                }
            },
            synthesis: DesktopOperationPlan.SynthesisRoute {
                throw PeekabooError.invalidInput(Self.unsupportedSetValueMessage(
                    target: resolved?.description ?? target,
                    reason: "Direct value setting is not supported for this element."))
            },
            postvalidate: { result in
                guard let resolved else {
                    throw PeekabooError.operationError(message: "Element mutation target was not prepared")
                }
                newValue = self.elementMutationValueReader(resolved.element)
                guard newValue != nil else {
                    throw DesktopActionFailure.indeterminate(
                        delivery: result.outcome.delivery,
                        evidence: .completionUnknown,
                        unitCount: result.outcome.dispatchState.unitCount,
                        message: "Accessibility value could not be verified after setting",
                        hint: "Observe the target before retrying this value mutation.")
                }
            },
            finalize: { self.elementDetectionService.invalidateCache() })
        self.logger.debug("Set value requested - target: \(target, privacy: .public)")
        let execution = try await self.normalizingSnapshotErrors {
            try await self.desktopOperationExecutor.executeWithTargetIdentity(plan)
        }
        let result = execution.payload
        guard let resolved, let newValue else {
            throw PeekabooError.operationError(message: "Element value result was not captured")
        }

        return UIAutomationActionResult(
            payload: ElementActionResult(
                target: resolved.description,
                actionName: result.actionName,
                anchorPoint: result.anchorPoint,
                oldValue: oldValue,
                newValue: newValue),
            outcome: result.outcome,
            targetIdentity: execution.targetIdentity)
    }

    public func performAction(
        target: String,
        actionName: String,
        snapshotId: String?) async throws -> ElementActionResult
    {
        try await self.performActionWithOutcome(
            target: target,
            actionName: actionName,
            snapshotId: snapshotId).payload
    }

    public func performActionWithOutcome(
        target: String,
        actionName: String,
        snapshotId: String?) async throws -> UIAutomationActionResult<ElementActionResult>
    {
        let requiredSnapshotId = try Self.requireElementActionSnapshotID(snapshotId)
        let captureReceipt = try await self.elementMutationCaptureReceipt(snapshotId: requiredSnapshotId)
        var resolved: ResolvedElementMutationTarget?
        let plan = try DesktopOperationPlan(
            verb: .performAction,
            selector: .element(target),
            captureReceipt: captureReceipt,
            strategy: self.inputPolicy.strategy(
                for: .performAction,
                bundleIdentifier: captureReceipt.bundleIdentifier),
            prepare: {
                guard Self.isValidActionName(actionName) else {
                    throw PeekabooError.invalidInput(
                        "Invalid action name '\(actionName)'. Use an accessibility action name such as AXPress.")
                }
                let target = try await self.resolveActionTarget(target, snapshotId: requiredSnapshotId)
                try self.validateElementMutationTarget(target.windowContext, receipt: captureReceipt)
                resolved = target
            },
            routing: {
                let bundleIdentifier = resolved?.bundleIdentifier ?? captureReceipt.bundleIdentifier
                return DesktopOperationPlan.Routing(
                    strategy: self.inputPolicy.strategy(for: .performAction, bundleIdentifier: bundleIdentifier),
                    bundleIdentifier: bundleIdentifier)
            },
            action: DesktopOperationPlan.ActionRoute {
                guard let resolved else {
                    throw PeekabooError.operationError(message: "Element action target was not prepared")
                }
                do {
                    return try self.actionInputDriver.tryPerformAction(
                        element: resolved.element,
                        actionName: actionName)
                } catch let error as ActionInputError where error.isUnsupportedActionInvocation {
                    throw PeekabooError.invalidInput(Self.unsupportedActionMessage(
                        actionName: actionName,
                        target: resolved.description,
                        advertisedActions: resolved.element.actionNames))
                }
            },
            synthesis: DesktopOperationPlan.SynthesisRoute {
                throw ActionInputError.unsupported(.actionUnsupported)
            },
            finalize: { self.elementDetectionService.invalidateCache() })
        let requestDescription = "Perform action requested - target: \(target), action: \(actionName)"
        self.logger.debug("\(requestDescription, privacy: .public)")
        let execution = try await self.normalizingSnapshotErrors {
            try await self.desktopOperationExecutor.executeWithTargetIdentity(plan)
        }
        let result = execution.payload
        guard resolved != nil else {
            throw PeekabooError.operationError(message: "Element action target was not prepared")
        }

        return UIAutomationActionResult(
            payload: ElementActionResult(
                target: target,
                actionName: result.actionName,
                anchorPoint: result.anchorPoint),
            outcome: result.outcome,
            targetIdentity: execution.targetIdentity)
    }

    private func resolveActionTarget(_ target: String, snapshotId: String) async throws
        -> ResolvedElementMutationTarget
    {
        let normalized = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw PeekabooError.invalidInput("Element target is required")
        }

        let detectionResult: ElementDetectionResult
        do {
            guard let result = try await self.snapshotManager.getDetectionResult(snapshotId: snapshotId) else {
                throw PeekabooError.snapshotNotFound(snapshotId)
            }
            detectionResult = result
        } catch let error as PeekabooError {
            throw error
        } catch {
            throw PeekabooError.snapshotNotFound(snapshotId)
        }

        if let detected = detectionResult.elements.findById(normalized) ??
            Self.findDetectedElement(matching: normalized, in: detectionResult)
        {
            guard !detected.isOCRSemanticEvidence else {
                throw PeekabooError.invalidInput(OCRSemanticEvidencePolicy.interactionRefusalMessage)
            }
            guard let element = self.automationElementResolver.resolve(
                detectedElement: detected,
                windowContext: detectionResult.metadata.windowContext)
            else {
                throw PeekabooError.snapshotStale("target element is no longer available")
            }
            return (
                element,
                Self.describe(detected),
                detectionResult.metadata.windowContext?.applicationBundleId,
                detectionResult.metadata.windowContext)
        }

        throw NotFoundError.element(normalized)
    }

    private static func requireElementActionSnapshotID(_ snapshotId: String?) throws -> String {
        guard let snapshotId = snapshotId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !snapshotId.isEmpty
        else {
            throw PeekabooError.snapshotNotAvailable(
                "Direct element actions require a current UI snapshot. Run 'peekaboo see' first, then retry " +
                    "with its element ID or snapshot context.")
        }
        return snapshotId
    }

    private static func findDetectedElement(matching query: String, in detectionResult: ElementDetectionResult)
        -> DetectedElement?
    {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return nil }

        return detectionResult.elements.all.first { element in
            guard !element.isOCRSemanticEvidence else { return false }
            return [
                element.label,
                element.value,
                element.attributes["title"],
                element.attributes["description"],
                element.attributes["identifier"],
                element.attributes["placeholder"],
            ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .contains { $0 == query || $0.contains(query) }
        }
    }

    private static func describe(_ element: DetectedElement) -> String {
        let label = element.label ?? element.value ?? element.attributes["title"] ?? "untitled"
        return "\(element.id) \(element.type.rawValue): \(label)"
    }

    private func elementMutationCaptureReceipt(snapshotId: String) async throws
        -> DesktopOperationPlan.CaptureReceipt
    {
        let detectionResult: ElementDetectionResult
        do {
            guard let result = try await self.snapshotManager.getDetectionResult(snapshotId: snapshotId) else {
                throw PeekabooError.snapshotNotFound(snapshotId)
            }
            detectionResult = result
        } catch let error as PeekabooError {
            throw error
        } catch {
            throw PeekabooError.snapshotNotFound(snapshotId)
        }
        return try DesktopOperationSnapshotReceiptValidator.captureReceipt(
            snapshotID: snapshotId,
            detectionResult: detectionResult,
            requireExactWindow: false,
            processStartIdentityProvider: self.processStartIdentityProvider,
            exactWindowIdentityValidator: self.exactWindowIdentityValidator)
    }

    private func validateElementMutationTarget(
        _ context: WindowContext?,
        receipt: DesktopOperationPlan.CaptureReceipt) throws
    {
        try DesktopOperationSnapshotReceiptValidator.validate(
            context: context,
            receipt: receipt,
            processStartIdentityProvider: self.processStartIdentityProvider,
            exactWindowIdentityValidator: self.exactWindowIdentityValidator)
    }

    private static func isValidActionName(_ actionName: String) -> Bool {
        guard !actionName.isEmpty else { return false }
        guard actionName.count <= 128 else { return false }
        return actionName.allSatisfy { character in
            character.isLetter || character.isNumber || character == "_" || character == "-"
        }
    }

    nonisolated static func unsupportedActionMessage(
        actionName: String,
        target: String,
        advertisedActions: [String]) -> String
    {
        let available = advertisedActions.isEmpty ? "none advertised" : advertisedActions.joined(separator: ", ")
        return "Action '\(actionName)' is not supported by \(target). Available actions: \(available)."
    }

    nonisolated static func unsupportedSetValueMessage(target: String, reason: String) -> String {
        "Cannot set value on \(target): \(reason)"
    }

    static func safeValueDescription(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            value
        case let value as Bool:
            String(value)
        case let value as Int:
            String(value)
        case let value as Double:
            String(value)
        case let value as Float:
            String(value)
        case let value?:
            String(describing: value)
        case nil:
            nil
        }
    }
}

extension ActionInputError {
    fileprivate var isUnsupportedActionInvocation: Bool {
        switch self {
        case .unsupported(.actionUnsupported), .unsupported(.attributeUnsupported):
            true
        case .unsupported, .staleElement, .permissionDenied, .targetUnavailable, .failed:
            false
        }
    }

    fileprivate var isUnsupportedValueMutation: Bool {
        switch self {
        case .unsupported(.attributeUnsupported),
             .unsupported(.valueNotSettable),
             .unsupported(.secureValueNotAllowed),
             .unsupported(.missingElement):
            true
        case .unsupported, .staleElement, .permissionDenied, .targetUnavailable, .failed:
            false
        }
    }
}
