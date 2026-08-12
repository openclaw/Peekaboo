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
        let requiredSnapshotId = try Self.requireElementActionSnapshotID(snapshotId)
        let captureReceipt = try await self.elementMutationCaptureReceipt(snapshotId: requiredSnapshotId)
        var resolved: ResolvedElementMutationTarget?
        var oldValue: String?
        var newValue: String?
        let plan = try DesktopOperationPlan(
            verb: .setValue,
            selector: .element(target),
            captureReceipt: captureReceipt,
            deliveryIntent: .background,
            strategy: self.inputPolicy.strategy(
                for: .setValue,
                bundleIdentifier: captureReceipt.bundleIdentifier),
            prepare: {
                let target = try await self.resolveActionTarget(target, snapshotId: requiredSnapshotId)
                try self.validateElementMutationTarget(target.windowContext, receipt: captureReceipt)
                resolved = target
                oldValue = self.safeValueDescription(target.element.value)
                    ?? target.element.selectedValue.map(String.init)
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
                newValue = self.safeValueDescription(resolved.element.value)
                    ?? resolved.element.selectedValue.map(String.init)
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
        let result = try await self.normalizingSnapshotErrors {
            try await self.desktopOperationExecutor.execute(plan)
        }
        guard let resolved, let newValue else {
            throw PeekabooError.operationError(message: "Element value result was not captured")
        }

        return ElementActionResult(
            target: resolved.description,
            actionName: result.actionName,
            anchorPoint: result.anchorPoint,
            oldValue: oldValue,
            newValue: newValue)
    }

    public func performAction(
        target: String,
        actionName: String,
        snapshotId: String?) async throws -> ElementActionResult
    {
        let requiredSnapshotId = try Self.requireElementActionSnapshotID(snapshotId)
        let captureReceipt = try await self.elementMutationCaptureReceipt(snapshotId: requiredSnapshotId)
        var resolved: ResolvedElementMutationTarget?
        let plan = try DesktopOperationPlan(
            verb: .performAction,
            selector: .element(target),
            captureReceipt: captureReceipt,
            deliveryIntent: .background,
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
        let result = try await self.normalizingSnapshotErrors {
            try await self.desktopOperationExecutor.execute(plan)
        }
        guard let resolved else {
            throw PeekabooError.operationError(message: "Element action target was not prepared")
        }

        return ElementActionResult(
            target: resolved.description,
            actionName: result.actionName,
            anchorPoint: result.anchorPoint)
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
        guard let detectionResult = try? await self.snapshotManager.getDetectionResult(snapshotId: snapshotId) else {
            return try DesktopOperationPlan.CaptureReceipt(snapshotID: snapshotId)
        }
        guard let context = detectionResult.metadata.windowContext,
              let identity = context.windowMutationIdentity
        else {
            return try DesktopOperationPlan.CaptureReceipt(
                snapshotID: snapshotId,
                bundleIdentifier: detectionResult.metadata.windowContext?.applicationBundleId,
                coordinateContext: detectionResult.metadata.captureCoordinateContext)
        }
        guard let bounds = context.windowBounds,
              context.applicationProcessId == identity.ownerProcessIdentifier,
              context.windowID == identity.windowID,
              identity.capturedBounds == bounds,
              self.processStartIdentityProvider(identity.ownerProcessIdentifier) ==
              identity.ownerProcessStartIdentity,
              self.exactWindowIdentityValidator(identity, bounds)
        else {
            throw PeekabooError.snapshotStale(
                "target window owner, process generation, or bounds changed before element mutation")
        }
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: identity.ownerProcessIdentifier,
            processStartIdentity: identity.ownerProcessStartIdentity)
        return try DesktopOperationPlan.CaptureReceipt(
            snapshotID: snapshotId,
            bundleIdentifier: context.applicationBundleId,
            processIdentifier: processIdentity.processIdentifier,
            processIdentity: processIdentity,
            exactWindow: DesktopOperationPlan.ExactWindowReceipt(identity: identity, bounds: bounds),
            coordinateContext: detectionResult.metadata.captureCoordinateContext)
    }

    private func validateElementMutationTarget(
        _ context: WindowContext?,
        receipt: DesktopOperationPlan.CaptureReceipt) throws
    {
        guard let expectedProcessIdentity = receipt.processIdentity,
              let exactWindow = receipt.exactWindow
        else {
            return
        }
        let expectedWindowIdentity = exactWindow.identity
        guard let context,
              context.applicationProcessId == expectedProcessIdentity.processIdentifier,
              context.windowID == expectedWindowIdentity.windowID,
              context.windowBounds == exactWindow.bounds,
              let resolvedWindowIdentity = context.windowMutationIdentity,
              Self.sameElementMutationWindowIdentity(resolvedWindowIdentity, expectedWindowIdentity),
              self.processStartIdentityProvider(expectedProcessIdentity.processIdentifier) ==
              expectedProcessIdentity.processStartIdentity,
              let bounds = expectedWindowIdentity.capturedBounds,
              self.exactWindowIdentityValidator(expectedWindowIdentity, bounds)
        else {
            throw PeekabooError.snapshotStale(
                "target window owner, process generation, or bounds changed before element mutation dispatch")
        }
    }

    private nonisolated static func sameElementMutationWindowIdentity(
        _ lhs: WindowMutationIdentity,
        _ rhs: WindowMutationIdentity) -> Bool
    {
        lhs.windowID == rhs.windowID &&
            lhs.ownerProcessIdentifier == rhs.ownerProcessIdentifier &&
            lhs.ownerProcessStartIdentity == rhs.ownerProcessStartIdentity &&
            lhs.capturedBounds == rhs.capturedBounds
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

    private func safeValueDescription(_ value: Any?) -> String? {
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
