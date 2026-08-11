import Foundation
import PeekabooFoundation

private struct ElementMutationLanePlan: Sendable {
    let scope: DesktopOperationScope
    let expectedProcessIdentity: ApplicationProcessIdentity?
    let expectedWindowIdentity: WindowMutationIdentity?

    static let global = ElementMutationLanePlan(
        scope: .global,
        expectedProcessIdentity: nil,
        expectedWindowIdentity: nil)
}

extension UIAutomationService: ElementActionAutomationServiceProtocol {
    public func setValue(
        target: String,
        value: UIElementValue,
        snapshotId: String?) async throws -> ElementActionResult
    {
        let requiredSnapshotId = try Self.requireElementActionSnapshotID(snapshotId)
        let lanePlan = try await self.elementMutationLanePlan(snapshotId: requiredSnapshotId)
        return try await self.operationLaneCoordinator.run(scope: lanePlan.scope, access: .write) {
            self.logger.debug("Set value requested - target: \(target, privacy: .public)")
            defer { self.elementDetectionService.invalidateCache() }
            let resolved = try await self.resolveActionTarget(target, snapshotId: requiredSnapshotId)
            try self.validateElementMutationTarget(resolved.windowContext, plan: lanePlan)
            let oldValue = self.safeValueDescription(resolved.element.value)
                ?? resolved.element.selectedValue.map(String.init)
            let result = try await self.normalizingSnapshotErrors {
                try await UIInputDispatcher.run(
                    verb: .setValue,
                    strategy: self.inputPolicy.strategy(for: .setValue, bundleIdentifier: resolved.bundleIdentifier),
                    bundleIdentifier: resolved.bundleIdentifier,
                    action: {
                        do {
                            return try self.actionInputDriver.trySetValue(element: resolved.element, value: value)
                        } catch let error as ActionInputError where error.isUnsupportedValueMutation {
                            throw PeekabooError.invalidInput(Self.unsupportedSetValueMessage(
                                target: resolved.description,
                                reason: error.localizedDescription))
                        }
                    },
                    synth: {
                        throw PeekabooError.invalidInput(Self.unsupportedSetValueMessage(
                            target: resolved.description,
                            reason: "Direct value setting is not supported for this element."))
                    })
            }
            guard let newValue = self.safeValueDescription(resolved.element.value)
                ?? resolved.element.selectedValue.map(String.init)
            else {
                throw PeekabooError.operationError(message: "Accessibility value could not be verified after setting")
            }

            return ElementActionResult(
                target: resolved.description,
                actionName: result.actionName,
                anchorPoint: result.anchorPoint,
                oldValue: oldValue,
                newValue: newValue)
        }
    }

    public func performAction(
        target: String,
        actionName: String,
        snapshotId: String?) async throws -> ElementActionResult
    {
        let requiredSnapshotId = try Self.requireElementActionSnapshotID(snapshotId)
        let lanePlan = try await self.elementMutationLanePlan(snapshotId: requiredSnapshotId)
        return try await self.operationLaneCoordinator.run(scope: lanePlan.scope, access: .write) {
            let requestDescription = "Perform action requested - target: \(target), action: \(actionName)"
            self.logger.debug("\(requestDescription, privacy: .public)")
            defer { self.elementDetectionService.invalidateCache() }
            guard Self.isValidActionName(actionName) else {
                throw PeekabooError.invalidInput(
                    "Invalid action name '\(actionName)'. Use an accessibility action name such as AXPress.")
            }

            let resolved = try await self.resolveActionTarget(target, snapshotId: requiredSnapshotId)
            try self.validateElementMutationTarget(resolved.windowContext, plan: lanePlan)
            let result = try await self.normalizingSnapshotErrors {
                try await UIInputDispatcher.run(
                    verb: .performAction,
                    strategy: self.inputPolicy.strategy(
                        for: .performAction,
                        bundleIdentifier: resolved.bundleIdentifier),
                    bundleIdentifier: resolved.bundleIdentifier,
                    action: {
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
                    synth: {
                        throw ActionInputError.unsupported(.actionUnsupported)
                    })
            }

            return ElementActionResult(
                target: resolved.description,
                actionName: result.actionName,
                anchorPoint: result.anchorPoint)
        }
    }

    private func resolveActionTarget(_ target: String, snapshotId: String) async throws
        -> (element: AutomationElement, description: String, bundleIdentifier: String?, windowContext: WindowContext?)
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
            [
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

    private func elementMutationLanePlan(snapshotId: String) async throws -> ElementMutationLanePlan {
        guard let detectionResult = try? await self.snapshotManager.getDetectionResult(snapshotId: snapshotId),
              let context = detectionResult.metadata.windowContext,
              let identity = context.windowMutationIdentity
        else {
            return .global
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
        return ElementMutationLanePlan(
            scope: .process(processIdentity),
            expectedProcessIdentity: processIdentity,
            expectedWindowIdentity: identity)
    }

    private func validateElementMutationTarget(
        _ context: WindowContext?,
        plan: ElementMutationLanePlan) throws
    {
        guard let expectedProcessIdentity = plan.expectedProcessIdentity,
              let expectedWindowIdentity = plan.expectedWindowIdentity
        else {
            return
        }
        guard let context,
              context.applicationProcessId == expectedProcessIdentity.processIdentifier,
              context.windowID == expectedWindowIdentity.windowID,
              context.windowBounds == expectedWindowIdentity.capturedBounds,
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
