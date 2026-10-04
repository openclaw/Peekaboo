import Foundation
import PeekabooFoundation

private struct ResolvedElementMutationTarget {
    let element: AutomationElement
    let description: String
    let bundleIdentifier: String?
    let windowContext: WindowContext?
    let elementIdentity: FocusedElementIdentity?
    let role: String?
}

extension UIAutomationService: ElementActionAutomationServiceProtocol {
    public var supportsTextSelection: Bool {
        true
    }

    public func selectText(
        target: String,
        request: TextSelectionRequest,
        snapshotId: String?) async throws -> UIAutomationActionResult<ElementActionResult>
    {
        guard !request.text.isEmpty else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest, message: "Selection text must not be empty")
        }
        let snapshotId = try Self.requireElementActionSnapshotID(snapshotId)
        let receipt = try await self.elementMutationCaptureReceipt(snapshotId: snapshotId)
        guard receipt.exactWindow != nil else {
            throw Self.elementMutationRefusal(
                "Text selection requires a fresh exact-window snapshot.", standardErrorCode: .snapshotStale)
        }
        var resolved: ResolvedElementMutationTarget?
        var selection: TextSelectionResult?
        let plan = try DesktopOperationPlan(
            verb: .selectText,
            selector: .element(target),
            captureReceipt: receipt,
            strategy: .actionOnly,
            prepare: {
                let element = try await self.resolveActionTarget(
                    target,
                    snapshotId: snapshotId,
                    targetProcessIdentifier: receipt.processIdentifier,
                    requireUniqueMatch: true)
                try self.validateElementMutationTarget(element, receipt: receipt)
                guard let identity = element.elementIdentity,
                      identity.windowID == receipt.exactWindow?.identity.windowID
                else {
                    throw Self.elementMutationRefusal(
                        "The selection target does not belong to the observed window.",
                        standardErrorCode: .snapshotStale)
                }
                resolved = element
            },
            action: DesktopOperationPlan.ActionRoute {
                guard let resolved else { throw PeekabooError.invalidInput("Selection target was not prepared") }
                let (action, result) = try await self.actionInputDriver.trySelectText(
                    element: resolved.element,
                    request: request,
                    beforeMutation: { try self.validateElementMutationTarget(resolved, receipt: receipt) })
                selection = result
                return action
            },
            synthesis: DesktopOperationPlan.SynthesisRoute {
                throw ActionInputError.unsupported(.attributeUnsupported)
            },
            finalize: { self.elementDetectionService.invalidateCache() })
        let execution = try await self.normalizingElementMutationErrors {
            try await self.desktopOperationExecutor.executeWithTargetIdentity(plan)
        }
        guard let selection else { throw PeekabooError.invalidInput("Selection result was not captured") }
        return UIAutomationActionResult(
            payload: ElementActionResult(
                target: target,
                actionName: "AXSelectedTextRange",
                anchorPoint: nil,
                textSelection: selection),
            outcome: execution.outcome,
            targetIdentity: execution.targetIdentity)
    }

    public var supportsSetValueResultTargetBinding: Bool {
        true
    }

    public var supportsProcessGenerationBoundElementMutations: Bool {
        true
    }

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
        var valueVerification: ElementValueVerification?
        let plan = try DesktopOperationPlan(
            verb: .setValue,
            selector: .element(target),
            captureReceipt: captureReceipt,
            strategy: self.inputPolicy.strategy(
                for: .setValue,
                bundleIdentifier: captureReceipt.bundleIdentifier),
            prepare: {
                let target = try await self.resolveActionTarget(
                    target,
                    snapshotId: requiredSnapshotId,
                    targetProcessIdentifier: captureReceipt.processIdentifier)
                try self.validateElementMutationTarget(target, receipt: captureReceipt)
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
                try self.validateElementMutationTarget(resolved, receipt: captureReceipt)
                do {
                    let action = try await self.actionInputDriver.trySetValue(
                        element: resolved.element,
                        value: value,
                        beforeMutation: {
                            try self.validateElementMutationTarget(resolved, receipt: captureReceipt)
                        })
                    valueVerification = action.valueVerification
                    return action
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
                if let valueVerification {
                    newValue = valueVerification.displayString
                    guard valueVerification.matches(
                        requested: value, newValue: newValue, actionName: result.actionName)
                    else {
                        throw DesktopActionFailure.indeterminate(
                            delivery: result.outcome.delivery,
                            evidence: .completionUnknown,
                            unitCount: result.outcome.dispatchState.unitCount,
                            message: "Accessibility value verification did not match its native result",
                            hint: "Observe the target before retrying this value mutation.")
                    }
                } else {
                    newValue = self.elementMutationValueReader(resolved.element)
                }
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
        let execution = try await self.normalizingElementMutationErrors {
            try await self.desktopOperationExecutor.executeWithTargetIdentity(plan)
        }
        let result = execution.payload
        guard resolved != nil, let newValue else {
            throw PeekabooError.operationError(message: "Element value result was not captured")
        }

        return UIAutomationActionResult(
            payload: ElementActionResult(
                target: target,
                actionName: result.actionName,
                anchorPoint: nil,
                oldValue: oldValue,
                newValue: newValue,
                valueVerification: valueVerification),
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
                let target = try await self.resolveActionTarget(
                    target,
                    snapshotId: requiredSnapshotId,
                    targetProcessIdentifier: captureReceipt.processIdentifier)
                try self.validateElementMutationTarget(target, receipt: captureReceipt)
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
                try self.validateElementMutationTarget(resolved, receipt: captureReceipt)
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
        let execution = try await self.normalizingElementMutationErrors {
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

    private func resolveActionTarget(
        _ target: String,
        snapshotId: String,
        targetProcessIdentifier: pid_t?,
        requireUniqueMatch: Bool = false) async throws
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
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch {
            throw Self.elementMutationRefusal(
                "Snapshot '\(snapshotId)' is no longer available for element mutation.",
                standardErrorCode: .snapshotNotFound,
                cause: error)
        }

        let exact = detectionResult.elements.findById(normalized)
        let matches = exact.map { [$0] } ?? Self.findDetectedElements(
            matching: normalized, in: detectionResult, limit: requireUniqueMatch ? 2 : 1)
        if requireUniqueMatch, matches.count > 1 {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest, message: "The element query is ambiguous; use its exact observed element ID.")
        }
        if let detected = matches.first {
            guard !detected.isOCRSemanticEvidence else {
                throw PeekabooError.invalidInput(OCRSemanticEvidencePolicy.interactionRefusalMessage)
            }
            guard let element = self.automationElementResolver.resolve(
                detectedElement: detected,
                windowContext: detectionResult.metadata.windowContext,
                targetProcessIdentifier: targetProcessIdentifier)
            else {
                throw Self.elementMutationRefusal(
                    "Target element is no longer available in the receipted process generation.",
                    standardErrorCode: .snapshotStale)
            }
            guard let targetProcessIdentifier,
                  AutomationElementResolver.processIdentifier(of: element) == targetProcessIdentifier
            else {
                throw Self.elementMutationRefusal(
                    "Resolved element belongs to a different process than the snapshot receipt.",
                    standardErrorCode: .snapshotStale)
            }
            return ResolvedElementMutationTarget(
                element: element,
                description: Self.describe(detected),
                bundleIdentifier: detectionResult.metadata.windowContext?.applicationBundleId,
                windowContext: detectionResult.metadata.windowContext,
                elementIdentity: element.focusedElementIdentity,
                role: element.role)
        }

        throw Self.elementMutationRefusal(
            "Element '\(normalized)' was not found in the receipted process generation.",
            standardErrorCode: .elementNotFound)
    }

    private static func requireElementActionSnapshotID(_ snapshotId: String?) throws -> String {
        guard let snapshotId = snapshotId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !snapshotId.isEmpty
        else {
            throw self.elementMutationRefusal(
                "Direct element actions require a current UI snapshot.",
                standardErrorCode: .snapshotNotFound)
        }
        return snapshotId
    }

    private static func findDetectedElements(
        matching query: String,
        in detectionResult: ElementDetectionResult,
        limit: Int)
        -> [DetectedElement]
    {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }

        return Array(detectionResult.elements.all.lazy.filter { element in
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
        }.prefix(limit))
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
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch {
            throw Self.elementMutationRefusal(
                "Snapshot '\(snapshotId)' is no longer available for element mutation.",
                standardErrorCode: .snapshotNotFound,
                cause: error)
        }
        return try DesktopOperationSnapshotReceiptValidator.captureReceipt(
            snapshotID: snapshotId,
            detectionResult: detectionResult,
            requireExactWindow: false,
            processStartIdentityProvider: self.processStartIdentityProvider,
            exactWindowIdentityValidator: self.exactWindowIdentityValidator)
    }

    private func validateElementMutationTarget(
        _ target: ResolvedElementMutationTarget,
        receipt: DesktopOperationPlan.CaptureReceipt) throws
    {
        try DesktopOperationSnapshotReceiptValidator.validate(
            context: target.windowContext,
            receipt: receipt,
            processStartIdentityProvider: self.processStartIdentityProvider,
            exactWindowIdentityValidator: self.exactWindowIdentityValidator)
        guard let processIdentifier = receipt.processIdentifier,
              AutomationElementResolver.processIdentifier(of: target.element) == processIdentifier
        else {
            throw Self.elementMutationRefusal(
                "Resolved element belongs to a different process than the snapshot receipt.",
                standardErrorCode: .snapshotStale)
        }
        if let expected = target.elementIdentity {
            guard let current = target.element.focusedElementIdentity,
                  FocusedElementReceiptResolver.matches(current, expected: expected)
            else {
                throw Self.elementMutationRefusal(
                    "The resolved element changed before mutation; capture a fresh target snapshot.",
                    standardErrorCode: .snapshotStale)
            }
        } else if target.element.focusedElementIdentity != nil || target.element.role != target.role {
            throw Self.elementMutationRefusal(
                "The resolved element changed before mutation; capture a fresh target snapshot.",
                standardErrorCode: .snapshotStale)
        }
    }

    private func normalizingElementMutationErrors<T>(
        _ operation: () async throws -> T) async throws -> T
    {
        do {
            return try await self.normalizingSnapshotErrors(operation)
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch let error as PeekabooError {
            switch error {
            case .snapshotNotFound, .snapshotNotAvailable:
                throw Self.elementMutationRefusal(
                    error.localizedDescription,
                    standardErrorCode: .snapshotNotFound,
                    cause: error)
            case .snapshotStale:
                throw Self.elementMutationRefusal(
                    error.localizedDescription,
                    standardErrorCode: .snapshotStale,
                    cause: error)
            default:
                throw error
            }
        }
    }

    private static func elementMutationRefusal(
        _ message: String,
        standardErrorCode: StandardErrorCode,
        cause: (any Error)? = nil) -> DesktopActionFailure
    {
        .preDispatchRefusal(
            reason: .targetUnavailable,
            message: message,
            hint: "Run 'peekaboo see' again and retry with its fresh target snapshot.",
            causeDescription: cause?.localizedDescription,
            standardErrorCode: standardErrorCode)
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
        NativeElementValuePresentation.describe(value)
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
