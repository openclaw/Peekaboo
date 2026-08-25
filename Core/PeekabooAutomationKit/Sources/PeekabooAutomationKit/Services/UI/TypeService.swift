import AppKit
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import os.log
import PeekabooFoundation

private struct PixelFocusSnapshotPreparationFailure: Error {
    let causeDescription: String
}

private struct PixelFocusSnapshotPreparationCancellation: Error {}

private struct PixelFocusActionPreDispatchCancellation: Error {}

private struct PixelFocusActionPreDispatchFailure: Error {
    let causeDescription: String
}

@MainActor
private final class PixelFocusPlanEntryState {
    var entered = false
}

/// Service for handling typing and text input operations
@MainActor
public final class TypeService {
    struct TypeExecutionSummary {
        let result: UIInputExecutionResult
        let typedIntoSecureField: Bool
    }

    struct TypeActionExecutionSummary {
        let result: TypeResult
        let executionResult: UIInputExecutionResult
        let typedIntoSecureField: Bool
    }

    private struct TypeActionPayloadSummary {
        let result: TypeResult
        let typedIntoSecureField: Bool
    }

    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "TypeService")
    let snapshotManager: any SnapshotManagerProtocol
    private let clickService: ClickService
    let cadenceRandom: any TypingCadenceRandomSource
    let inputPolicy: UIInputPolicy
    private let actionInputDriver: any ActionInputDriving
    private let syntheticInputDriver: any SyntheticInputDriving
    private let automationElementResolver: any AutomationElementResolving
    private let focusedElementSecurityProbe: @MainActor (pid_t?) -> Bool
    private let targetedCharacterTyper: @MainActor (Character, pid_t) throws -> Void
    private let desktopOperationExecutor: DesktopOperationExecutor
    private let operationFinalizer: @MainActor () -> Void
    private let pixelFocusReceiptPlanner: @MainActor @Sendable (String) async throws -> SnapshotTargetReceiptPlan
    private let pixelFocusPlanEntryHook: @MainActor @Sendable () async throws -> Void
    private let exactFocusedElementValueReader: @Sendable (FocusedElementIdentity)
        -> Result<ExactWindowFocusSnapshot, FocusedElementReceiptError>
    private let processStartIdentityProvider: @Sendable (pid_t) -> UInt64?

    public convenience init(
        snapshotManager: (any SnapshotManagerProtocol)? = nil,
        clickService: ClickService? = nil,
        inputPolicy: UIInputPolicy = .currentBehavior)
    {
        self.init(
            snapshotManager: snapshotManager,
            clickService: clickService,
            inputPolicy: inputPolicy,
            actionInputDriver: ActionInputDriver(),
            syntheticInputDriver: SyntheticInputDriver(),
            automationElementResolver: AutomationElementResolver())
    }

    convenience init(
        snapshotManager: (any SnapshotManagerProtocol)? = nil,
        clickService: ClickService? = nil,
        inputPolicy: UIInputPolicy = .currentBehavior,
        actionInputDriver: any ActionInputDriving = ActionInputDriver(),
        syntheticInputDriver: any SyntheticInputDriving = SyntheticInputDriver(),
        automationElementResolver: any AutomationElementResolving = AutomationElementResolver(),
        exactFocusedElementValueReader: @escaping @Sendable (FocusedElementIdentity)
            -> Result<ExactWindowFocusSnapshot, FocusedElementReceiptError> = DetachedExactWindowFocusReader.readValue,
        processStartIdentityProvider: @escaping @Sendable (pid_t) -> UInt64? =
            SystemIdentityResolver.processStartIdentity,
        desktopOperationExecutor: DesktopOperationExecutor = DesktopOperationExecutor(),
        operationFinalizer: @escaping @MainActor () -> Void = {})
    {
        self.init(
            snapshotManager: snapshotManager,
            clickService: clickService,
            inputPolicy: inputPolicy,
            actionInputDriver: actionInputDriver,
            syntheticInputDriver: syntheticInputDriver,
            automationElementResolver: automationElementResolver,
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: Self.focusedElementIsSecureField,
            exactFocusedElementValueReader: exactFocusedElementValueReader,
            processStartIdentityProvider: processStartIdentityProvider,
            desktopOperationExecutor: desktopOperationExecutor,
            operationFinalizer: operationFinalizer)
    }

    init(
        snapshotManager: (any SnapshotManagerProtocol)? = nil,
        clickService: ClickService? = nil,
        inputPolicy: UIInputPolicy = .currentBehavior,
        actionInputDriver: any ActionInputDriving = ActionInputDriver(),
        syntheticInputDriver: any SyntheticInputDriving = SyntheticInputDriver(),
        automationElementResolver: any AutomationElementResolving = AutomationElementResolver(),
        randomSource: any TypingCadenceRandomSource,
        focusedElementSecurityProbe: @escaping @MainActor (pid_t?) -> Bool = TypeService.focusedElementIsSecureField,
        targetedCharacterTyper: @escaping @MainActor (Character, pid_t) throws -> Void = TypeService
            .typeTargetedCharacter,
        exactFocusedElementValueReader: @escaping @Sendable (FocusedElementIdentity)
            -> Result<ExactWindowFocusSnapshot, FocusedElementReceiptError> = DetachedExactWindowFocusReader.readValue,
        processStartIdentityProvider: @escaping @Sendable (pid_t) -> UInt64? =
            SystemIdentityResolver.processStartIdentity,
        desktopOperationExecutor: DesktopOperationExecutor = DesktopOperationExecutor(),
        operationFinalizer: @escaping @MainActor () -> Void = {},
        pixelFocusReceiptPlanner: (@MainActor @Sendable (String) async throws -> SnapshotTargetReceiptPlan)? = nil,
        pixelFocusPlanEntryHook: @escaping @MainActor @Sendable () async throws -> Void = {})
    {
        let manager = snapshotManager ?? SnapshotManager()
        self.snapshotManager = manager
        self.clickService = clickService ?? ClickService(
            snapshotManager: manager,
            inputPolicy: inputPolicy,
            actionInputDriver: actionInputDriver,
            syntheticInputDriver: syntheticInputDriver,
            automationElementResolver: automationElementResolver,
            desktopOperationExecutor: desktopOperationExecutor,
            operationFinalizer: operationFinalizer)
        self.inputPolicy = inputPolicy
        self.actionInputDriver = actionInputDriver
        self.syntheticInputDriver = syntheticInputDriver
        self.automationElementResolver = automationElementResolver
        self.cadenceRandom = randomSource
        self.focusedElementSecurityProbe = focusedElementSecurityProbe
        self.targetedCharacterTyper = targetedCharacterTyper
        self.exactFocusedElementValueReader = exactFocusedElementValueReader
        self.processStartIdentityProvider = processStartIdentityProvider
        self.desktopOperationExecutor = desktopOperationExecutor
        self.operationFinalizer = operationFinalizer
        self.pixelFocusReceiptPlanner = pixelFocusReceiptPlanner ?? { snapshotID in
            try await SnapshotTargetReceiptPlanner(snapshots: manager).plan(snapshotID: snapshotID)
        }
        self.pixelFocusPlanEntryHook = pixelFocusPlanEntryHook
    }

    /// Type text with optional target and settings
    @discardableResult
    @MainActor
    public func type(
        text: String,
        target: String?,
        clearExisting: Bool,
        typingDelay: Int,
        snapshotId: String?) async throws -> UIInputExecutionResult
    {
        try await self.typeTrackingSecureInput(
            text: text,
            target: target,
            clearExisting: clearExisting,
            typingDelay: typingDelay,
            snapshotId: snapshotId).result
    }

    func typeTrackingSecureInput(
        text: String,
        target: String?,
        clearExisting: Bool,
        typingDelay: Int,
        snapshotId: String?,
        lanePreparation: @escaping @MainActor () async -> Void = {},
        laneCompletion: @escaping @MainActor (UIInputExecutionResult, Bool) async -> Void = { _, _ in })
        async throws -> TypeExecutionSummary
    {
        self.logger
            .debug("Type requested - text: '\(text)', target: \(target ?? "current focus"), clear: \(clearExisting)")
        var bundleIdentifier: String?
        var typedIntoSecureField = false
        let plan = try DesktopOperationPlan(
            verb: .type,
            selector: .element(target),
            captureReceipt: DesktopOperationPlan.CaptureReceipt(
                snapshotID: snapshotId,
                target: .foreground),
            strategy: self.inputPolicy.strategy(for: .type),
            prepare: {
                bundleIdentifier = await self.bundleIdentifier(snapshotId: snapshotId)
                typedIntoSecureField = if let target {
                    await self.typingTargetIsSecureField(target: target, snapshotId: snapshotId)
                } else {
                    self.focusedElementSecurityProbe(nil)
                }
                await lanePreparation()
            },
            routing: {
                DesktopOperationPlan.Routing(
                    strategy: self.inputPolicy.strategy(for: .type, bundleIdentifier: bundleIdentifier),
                    bundleIdentifier: bundleIdentifier)
            },
            action: DesktopOperationPlan.ActionRoute {
                try await self.performActionType(
                    text: text,
                    target: target,
                    clearExisting: clearExisting,
                    snapshotId: snapshotId)
            },
            synthesis: DesktopOperationPlan.SynthesisRoute {
                try await self.performSyntheticType(
                    text: text,
                    target: target,
                    clearExisting: clearExisting,
                    typingDelay: typingDelay,
                    snapshotId: snapshotId)
            },
            success: { result in await laneCompletion(result, typedIntoSecureField) },
            finalize: self.operationFinalizer)
        let result = try await self.desktopOperationExecutor.execute(plan)

        self.logger.debug("Type completed via \(result.path.rawValue, privacy: .public)")
        return TypeExecutionSummary(result: result, typedIntoSecureField: typedIntoSecureField)
    }

    private func performActionType(
        text: String,
        target: String?,
        clearExisting: Bool,
        snapshotId: String?) async throws -> UIInputExecutionResult.Action
    {
        guard let target,
              let element = try await self.resolveAutomationElement(target: target, snapshotId: snapshotId)
        else {
            throw ActionInputError.unsupported(.missingElement)
        }

        return try self.actionInputDriver.trySetText(
            element: element,
            text: text,
            replace: clearExisting)
    }

    private func performSyntheticType(
        text: String,
        target: String?,
        clearExisting: Bool,
        typingDelay: Int,
        snapshotId: String?) async throws -> DesktopActionOutcome
    {
        // If target specified, click on it first
        if let target {
            var elementFound = false
            var elementFrame: CGRect?
            var elementId: String?

            // Try to find element by ID first
            if let snapshotId,
               let detectionResult = try? await snapshotManager.getDetectionResult(snapshotId: snapshotId),
               let element = detectionResult.elements.findById(target)
            {
                guard !element.isOCRSemanticEvidence else {
                    throw PeekabooError.invalidInput(OCRSemanticEvidencePolicy.interactionRefusalMessage)
                }
                elementFound = true
                elementFrame = element.bounds
                elementId = element.id
            }

            // If not found by ID, search by query
            if !elementFound {
                let searchResult = try await findAndClickElement(query: target, snapshotId: snapshotId)
                elementFound = searchResult.found
                elementFrame = searchResult.frame
            }

            if elementFound {
                if let elementId {
                    _ = try await self.clickService.clickOwned(
                        target: .elementId(elementId),
                        clickType: .single,
                        snapshotId: snapshotId)
                } else if let frame = elementFrame {
                    let center = CGPoint(x: frame.midX, y: frame.midY)
                    let adjusted = try await self.resolveAdjustedPoint(center, snapshotId: snapshotId)
                    _ = try await self.clickService.clickOwned(
                        target: .coordinates(adjusted),
                        clickType: .single,
                        snapshotId: snapshotId)
                }

                // Small delay after click
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            } else {
                throw NotFoundError.element(target)
            }
        }

        // Clear existing text if requested
        if clearExisting {
            _ = try await self.clearCurrentField()
        }

        // Type the text
        try await self.typeTextWithDelay(text, delay: TimeInterval(typingDelay) / 1000.0)

        self.logger.debug("Successfully typed \(text.count) characters")
        return .dispatchedUnverified(
            delivery: DesktopActionOutcome.Delivery(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted)
    }

    /// Type actions (advanced typing with special keys)
    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?) async throws -> TypeResult
    {
        try await self.typeActionsTrackingSecureInput(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            targetProcessIdentifier: nil).result
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: pid_t?) async throws -> TypeResult
    {
        try await self.typeActionsTrackingSecureInput(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier).result
    }

    func typeActionsTrackingSecureInput(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: pid_t?,
        deliveryValidator: (@MainActor @Sendable () async throws -> Void)? = nil,
        expectedProcessIdentity: ApplicationProcessIdentity? = nil,
        lanePreparation: @escaping @MainActor () async -> Void = {},
        laneCompletion: @escaping @MainActor (TypeActionExecutionSummary) async -> Void = { _ in }) async throws
        -> TypeActionExecutionSummary
    {
        let automationTarget: UIAutomationTarget = if let targetProcessIdentifier {
            try .process(UIAutomationTarget.Process(
                processIdentifier: targetProcessIdentifier,
                identity: expectedProcessIdentity))
        } else {
            .foreground
        }
        return try await self.typeActionsTrackingSecureInput(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            automationTarget: automationTarget,
            deliveryValidator: deliveryValidator,
            lanePreparation: lanePreparation,
            laneCompletion: laneCompletion)
    }

    func typeActionsTrackingSecureInput(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        automationTarget: UIAutomationTarget,
        deliveryValidator: (@MainActor @Sendable () async throws -> Void)? = nil,
        lanePreparation: @escaping @MainActor () async -> Void = {},
        laneCompletion: @escaping @MainActor (TypeActionExecutionSummary) async -> Void = { _ in }) async throws
        -> TypeActionExecutionSummary
    {
        var payloadSummary: TypeActionPayloadSummary?
        var summary: TypeActionExecutionSummary?
        let targetProcessIdentifier = automationTarget.processIdentifier
        let effectConfirmation = automationTarget.exactWindow.flatMap {
            ExactLiteralTypingEffectConfirmation.plan(actions: actions, target: $0)
        }
        var confirmationPreflightValue: String?
        let plan = try DesktopOperationPlan(
            verb: .type,
            selector: .focused,
            captureReceipt: DesktopOperationPlan.CaptureReceipt(
                snapshotID: snapshotId,
                target: automationTarget),
            strategy: targetProcessIdentifier == nil ? self.inputPolicy.strategy(for: .type) : .synthOnly,
            prepare: {
                confirmationPreflightValue = await self.prepareEffectConfirmationBaseline(
                    effectConfirmation,
                    lanePreparation: lanePreparation)
            },
            action: nil,
            synthesis: DesktopOperationPlan.SynthesisRoute {
                payloadSummary = try await self.performSyntheticTypeActions(
                    actions,
                    cadence: cadence,
                    snapshotId: snapshotId,
                    targetProcessIdentifier: targetProcessIdentifier,
                    deliveryValidator: deliveryValidator)
                return .dispatchedUnverified(
                    delivery: automationTarget.keyboardDelivery,
                    evidence: .deliveryAccepted)
            },
            success: { executionResult in
                guard let payloadSummary else {
                    return
                }
                var verifiedExecutionResult = executionResult
                if let effectConfirmation,
                   let confirmationPreflightValue,
                   let observedValue = await self.exactFocusedValue(for: effectConfirmation)
                {
                    verifiedExecutionResult.outcome = effectConfirmation.confirmedOutcome(
                        from: executionResult.outcome,
                        previousValue: confirmationPreflightValue,
                        observedValue: observedValue)
                }
                let completedSummary = TypeActionExecutionSummary(
                    result: payloadSummary.result,
                    executionResult: verifiedExecutionResult,
                    typedIntoSecureField: payloadSummary.typedIntoSecureField)
                summary = completedSummary
                await laneCompletion(completedSummary)
            },
            finalize: self.operationFinalizer)
        _ = try await self.desktopOperationExecutor.execute(plan)

        guard let summary else {
            throw PeekabooError.operationError(message: "Type action execution did not produce a result")
        }
        return summary
    }

    func prepareEffectConfirmationBaseline(
        _ confirmation: ExactLiteralTypingEffectConfirmation?,
        lanePreparation: @escaping @MainActor () async -> Void) async -> String?
    {
        await lanePreparation()
        guard let confirmation else { return nil }
        return await self.exactFocusedValue(for: confirmation)
    }

    func exactFocusedValue(
        for confirmation: ExactLiteralTypingEffectConfirmation) async -> String?
    {
        let reader = self.exactFocusedElementValueReader
        let processStartIdentityProvider = self.processStartIdentityProvider
        let focusedElement = confirmation.focusedElement
        let expectedGeneration = confirmation.processStartIdentity
        let observation = try? await ElementDetectionTimeoutRunner.runDetached(
            targetProcessIdentifier: focusedElement.processIdentifier,
            targetProcessStartIdentity: expectedGeneration,
            seconds: 0.2)
        {
            guard processStartIdentityProvider(focusedElement.processIdentifier) == expectedGeneration else {
                return Result<ExactWindowFocusSnapshot, FocusedElementReceiptError>.failure(.processMismatch)
            }
            let observation = reader(focusedElement)
            guard processStartIdentityProvider(focusedElement.processIdentifier) == expectedGeneration else {
                return Result<ExactWindowFocusSnapshot, FocusedElementReceiptError>.failure(.processMismatch)
            }
            return observation
        }
        return observation.flatMap(confirmation.readableValue(from:))
    }

    private func performSyntheticTypeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId _: String?,
        targetProcessIdentifier: pid_t?,
        deliveryValidator: (@MainActor @Sendable () async throws -> Void)?) async throws
        -> TypeActionPayloadSummary
    {
        var totalChars = 0
        var keyPresses = 0
        var emittedUnitCount = 0
        var typedIntoSecureField = false
        var humanContext: HumanTypingContext?
        let fixedDelay = self.fixedDelaySeconds(for: cadence)

        self.logger.debug("Processing \(actions.count) type actions with cadence: \(cadence.logDescription)")

        do {
            for action in actions {
                switch action {
                case let .text(text):
                    if Self.actionTypesSensitiveText(
                        action,
                        focusedElementIsSecure: self.focusedElementSecurityProbe(targetProcessIdentifier))
                    {
                        typedIntoSecureField = true
                    }
                    for character in text {
                        try await self.validateDelivery(
                            deliveryValidator,
                            emittedUnitCount: emittedUnitCount)
                        do {
                            try await self.typeCharacter(character, targetProcessIdentifier: targetProcessIdentifier)
                        } catch let error as InputDeliveryIndeterminateError {
                            throw error
                        } catch {
                            throw Self.indeterminateDeliveryError(
                                from: error,
                                emittedUnitCount: emittedUnitCount > 0 ? emittedUnitCount : nil)
                        }
                        totalChars += 1
                        keyPresses += 1
                        emittedUnitCount += 1
                        try await self.sleepAfterKeystroke(
                            typedCharacter: character,
                            cadence: cadence,
                            fixedDelaySeconds: fixedDelay,
                            humanContext: &humanContext)
                    }

                case let .key(key):
                    try await self.validateDelivery(
                        deliveryValidator,
                        emittedUnitCount: emittedUnitCount)
                    do {
                        try self.typeSpecialKey(key, targetProcessIdentifier: targetProcessIdentifier)
                    } catch let error as InputDeliveryIndeterminateError {
                        throw error
                    } catch {
                        throw Self.indeterminateDeliveryError(
                            from: error,
                            emittedUnitCount: emittedUnitCount > 0 ? emittedUnitCount : nil)
                    }
                    keyPresses += 1
                    emittedUnitCount += 1
                    try await self.sleepAfterKeystroke(
                        typedCharacter: nil,
                        cadence: cadence,
                        fixedDelaySeconds: fixedDelay,
                        humanContext: &humanContext)

                case .clear:
                    emittedUnitCount += try await self.clearCurrentField(
                        targetProcessIdentifier: targetProcessIdentifier,
                        deliveryValidator: deliveryValidator,
                        priorEmittedUnitCount: emittedUnitCount)
                    keyPresses += 2 // Cmd+A and Delete
                    try await self.sleepAfterKeystroke(
                        typedCharacter: nil,
                        cadence: cadence,
                        fixedDelaySeconds: fixedDelay,
                        humanContext: &humanContext)
                }
            }

            try await self.validateDelivery(
                deliveryValidator,
                emittedUnitCount: emittedUnitCount)
        } catch let error as InputDeliveryIndeterminateError {
            throw error
        } catch {
            guard emittedUnitCount > 0 else { throw error }
            throw Self.indeterminateDeliveryError(
                from: error,
                emittedUnitCount: emittedUnitCount)
        }

        return TypeActionPayloadSummary(
            result: TypeResult(
                totalCharacters: totalChars,
                keyPresses: keyPresses),
            typedIntoSecureField: typedIntoSecureField)
    }

    /// Sample the actual delivery scope immediately before each text segment.
    /// This catches focus-changing sequences such as Tab → password → Return,
    /// where before/after samples both observe a non-secure field.
    static func focusedElementIsSecureField(processIdentifier: pid_t? = nil) -> Bool {
        let container: AXUIElement = if let processIdentifier {
            AXUIElementCreateApplication(processIdentifier)
        } else {
            AXUIElementCreateSystemWide()
        }

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            container,
            kAXFocusedUIElementAttribute as CFString,
            &focused) == .success,
            let focused,
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            return false
        }

        let element = unsafeDowncast(focused, to: AXUIElement.self)
        func stringAttribute(_ name: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value as? String
        }

        return stringAttribute(kAXRoleAttribute as String) == "AXSecureTextField"
            || stringAttribute(kAXSubroleAttribute as String) == "AXSecureTextField"
    }

    static func actionTypesSensitiveText(_ action: TypeAction, focusedElementIsSecure: Bool) -> Bool {
        guard focusedElementIsSecure, case let .text(text) = action else { return false }
        return !text.isEmpty
    }

    /// Whether a typing target resolves to a secure (password) field, so the
    /// visualizer masks its caption. The resolved destination element is
    /// authoritative — focus sampling can miss it when the target is focused
    /// only mid-flow and a trailing submit key moves focus afterwards.
    /// Resolution failures err on not-secure; delivery fails the same way.
    func typingTargetIsSecureField(target: String, snapshotId: String?) async -> Bool {
        guard let element = try? await self.resolveAutomationElement(target: target, snapshotId: snapshotId) else {
            return false
        }
        return element.role == "AXSecureTextField" || element.subrole == "AXSecureTextField"
    }

    private func resolveAutomationElement(target: String, snapshotId: String?) async throws -> AutomationElement? {
        if let snapshotId {
            guard let detectionResult = try? await self.snapshotManager.getDetectionResult(snapshotId: snapshotId)
            else {
                throw ActionInputError.staleElement
            }

            if let element = detectionResult.elements.findById(target) ??
                Self.resolveTargetElement(query: target, in: detectionResult)
            {
                guard !element.isOCRSemanticEvidence else {
                    throw PeekabooError.invalidInput(OCRSemanticEvidencePolicy.interactionRefusalMessage)
                }
                guard let resolved = self.automationElementResolver.resolve(
                    detectedElement: element,
                    windowContext: detectionResult.metadata.windowContext)
                else {
                    throw ActionInputError.staleElement
                }
                return resolved
            }

            throw NotFoundError.element(target)
        }

        return self.automationElementResolver.resolve(query: target, windowContext: nil, requireTextInput: true)
    }

    private func bundleIdentifier(snapshotId: String?) async -> String? {
        if let snapshotId,
           let detectionResult = try? await self.snapshotManager.getDetectionResult(snapshotId: snapshotId),
           let bundleIdentifier = detectionResult.metadata.windowContext?.applicationBundleId
        {
            return bundleIdentifier
        }

        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    // MARK: - Input Helpers

    private func clearCurrentField(
        targetProcessIdentifier: pid_t? = nil,
        deliveryValidator: (@MainActor @Sendable () async throws -> Void)? = nil,
        priorEmittedUnitCount: Int = 0) async throws -> Int
    {
        self.logger.debug("Clearing current field")
        try await self.validateDelivery(
            deliveryValidator,
            emittedUnitCount: priorEmittedUnitCount)

        if let targetProcessIdentifier {
            do {
                if try BackgroundInputDriver.replaceFocusedText(
                    with: "",
                    targetProcessIdentifier: targetProcessIdentifier)
                {
                    do {
                        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    } catch {
                        throw Self.indeterminateDeliveryError(
                            from: error,
                            emittedUnitCount: priorEmittedUnitCount + 1)
                    }
                    return 1
                }
            } catch let error as InputDeliveryIndeterminateError {
                throw error
            } catch {
                throw Self.indeterminateDeliveryError(
                    from: error,
                    emittedUnitCount: priorEmittedUnitCount > 0 ? priorEmittedUnitCount : nil)
            }

            do {
                try BackgroundInputDriver.tapKey(
                    keyCode: 0x00,
                    modifiers: .maskCommand,
                    targetProcessIdentifier: targetProcessIdentifier)
            } catch {
                throw Self.indeterminateDeliveryError(
                    from: error,
                    emittedUnitCount: priorEmittedUnitCount > 0 ? priorEmittedUnitCount : nil)
            }
        } else {
            do {
                try self.syntheticInputDriver.hotkey(keys: ["cmd", "a"], holdDuration: 0.1)
            } catch {
                throw Self.indeterminateDeliveryError(
                    from: error,
                    emittedUnitCount: priorEmittedUnitCount > 0 ? priorEmittedUnitCount : nil)
            }
        }
        do {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        } catch {
            throw Self.indeterminateDeliveryError(
                from: error,
                emittedUnitCount: priorEmittedUnitCount + 1)
        }

        try await self.validateDelivery(
            deliveryValidator,
            emittedUnitCount: priorEmittedUnitCount + 1)
        if let targetProcessIdentifier {
            do {
                try BackgroundInputDriver.tapKey(
                    keyCode: TypeServiceSpecialKeyMapping.keyCode(for: .delete),
                    targetProcessIdentifier: targetProcessIdentifier)
            } catch {
                throw Self.indeterminateDeliveryError(
                    from: error,
                    emittedUnitCount: priorEmittedUnitCount + 1)
            }
        } else {
            do {
                try self.syntheticInputDriver.tapKey(.delete, modifiers: [])
            } catch {
                throw Self.indeterminateDeliveryError(
                    from: error,
                    emittedUnitCount: priorEmittedUnitCount + 1)
            }
        }
        do {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        } catch {
            throw Self.indeterminateDeliveryError(
                from: error,
                emittedUnitCount: priorEmittedUnitCount + 2)
        }
        return 2
    }

    private func validateDelivery(
        _ deliveryValidator: (@MainActor @Sendable () async throws -> Void)?,
        emittedUnitCount: Int) async throws
    {
        guard let deliveryValidator else { return }

        do {
            try await deliveryValidator()
        } catch let error as InputDeliveryIndeterminateError {
            throw error
        } catch {
            guard emittedUnitCount > 0 else { throw error }
            throw InputDeliveryIndeterminateError(
                operation: .type,
                emittedUnitCount: emittedUnitCount,
                causeDescription: error.localizedDescription)
        }
    }

    private static func indeterminateDeliveryError(
        from error: any Error,
        emittedUnitCount: Int?) -> InputDeliveryIndeterminateError
    {
        if let error = error as? InputDeliveryIndeterminateError {
            return error
        }
        return InputDeliveryIndeterminateError(
            operation: .type,
            emittedUnitCount: emittedUnitCount,
            causeDescription: error.localizedDescription)
    }

    private func typeTextWithDelay(_ text: String, delay: TimeInterval) async throws {
        for char in text {
            try await self.typeCharacter(char)

            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func typeCharacter(_ char: Character, targetProcessIdentifier: pid_t? = nil) async throws {
        if let targetProcessIdentifier {
            try self.targetedCharacterTyper(char, targetProcessIdentifier)
        } else {
            try self.syntheticInputDriver.type(String(char), delayPerCharacter: 0)
        }
    }

    private static func typeTargetedCharacter(_ char: Character, targetProcessIdentifier: pid_t) throws {
        if try BackgroundInputDriver.insertTextIntoFocusedText(
            String(char),
            targetProcessIdentifier: targetProcessIdentifier)
        {
            return
        }
        try BackgroundInputDriver.typeCharacter(char, targetProcessIdentifier: targetProcessIdentifier)
    }
}

extension TypeService {
    func typeActionsByFocusingPixel(
        _ request: ExactWindowPixelFocusTypeRequest,
        deliveryValidator: @escaping @MainActor @Sendable (
            FocusedElementIdentity) async throws -> Void) async throws
        -> UIAutomationActionResult<TypeResult>
    {
        guard request.point.x.isFinite, request.point.y.isFinite else {
            throw PeekabooError.invalidInput("Pixel-focus coordinates must be finite")
        }
        guard !request.actions.isEmpty else {
            throw PeekabooError.invalidInput("Pixel-focus typing requires at least one typing action")
        }
        guard Self.plannedKeyPressCount(request.actions) > 0 else {
            throw PeekabooError.invalidInput("Pixel-focus typing requires at least one keyboard unit")
        }
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: request.windowIdentity,
            bounds: request.windowBounds)

        let lease = try await self.snapshotManager.beginSnapshotMutation(snapshotId: request.snapshotID)
        let planEntryState = PixelFocusPlanEntryState()
        let result: UIAutomationActionResult<TypeResult>
        do {
            result = try await self.executePixelFocusType(
                request,
                exactWindow: exactWindow,
                deliveryValidator: deliveryValidator,
                planDidEnter: { planEntryState.entered = true })
        } catch let error as SnapshotTargetReceiptPreDispatchError {
            try? await self.snapshotManager.finishSnapshotMutation(
                lease,
                requiresFreshObservation: false)
            throw error
        } catch let error as PixelFocusSnapshotPreparationFailure {
            try? await self.snapshotManager.finishSnapshotMutation(
                lease,
                requiresFreshObservation: false)
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Pixel-focus typing could not validate its snapshot before dispatch.",
                hint: "Observe the exact target again before retrying.",
                causeDescription: error.causeDescription)
        } catch is PixelFocusSnapshotPreparationCancellation {
            try? await self.snapshotManager.finishSnapshotMutation(
                lease,
                requiresFreshObservation: false)
            throw CancellationError()
        } catch is PixelFocusActionPreDispatchCancellation {
            try? await self.snapshotManager.finishSnapshotMutation(
                lease,
                requiresFreshObservation: false)
            throw CancellationError()
        } catch is CancellationError {
            guard !planEntryState.entered else { throw CancellationError() }
            try? await self.snapshotManager.finishSnapshotMutation(
                lease,
                requiresFreshObservation: false)
            throw CancellationError()
        } catch let error as PixelFocusActionPreDispatchFailure {
            try? await self.snapshotManager.finishSnapshotMutation(
                lease,
                requiresFreshObservation: false)
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .permissionDenied,
                message: "Pixel-focus typing could not establish Accessibility focus before dispatch.",
                hint: "Grant Accessibility permission before retrying.",
                causeDescription: error.causeDescription)
                .attributed(to: DesktopTargetIdentity(exactWindow: exactWindow).actionTargetReceipt)
        } catch let failure as DesktopActionFailure {
            try? await self.snapshotManager.finishSnapshotMutation(
                lease,
                requiresFreshObservation: failure.outcome.projection.requiresFreshObservation)
            throw failure
        } catch {
            try? await self.snapshotManager.finishSnapshotMutation(
                lease,
                requiresFreshObservation: true)
            throw DesktopActionFailure.indeterminate(
                evidence: .completionUnknown,
                message: "Pixel-focus typing failed without a canonical action outcome.",
                hint: "Observe the exact target before any retry and do not reuse this snapshot.",
                causeDescription: error.localizedDescription)
                .attributed(to: DesktopTargetIdentity(exactWindow: exactWindow).actionTargetReceipt)
        }
        do {
            try await self.snapshotManager.finishSnapshotMutation(
                lease,
                requiresFreshObservation: result.outcome?.projection.requiresFreshObservation ?? true)
        } catch {
            throw DesktopActionFailure.indeterminate(
                route: result.outcome?.route ?? .local,
                delivery: result.outcome?.delivery,
                evidence: .completionUnknown,
                unitCount: result.outcome?.dispatchState.unitCount,
                message: "Pixel-focus typing completed, but its snapshot mutation lease could not be finalized.",
                hint: "Observe the exact target before any retry and do not reuse this snapshot.",
                causeDescription: error.localizedDescription)
                .attributed(to: DesktopTargetIdentity(exactWindow: exactWindow).actionTargetReceipt)
        }
        return result
    }

    private func executePixelFocusType(
        _ request: ExactWindowPixelFocusTypeRequest,
        exactWindow: UIAutomationTarget.ExactWindow,
        deliveryValidator: @escaping @MainActor @Sendable (
            FocusedElementIdentity) async throws -> Void,
        planDidEnter: @escaping @MainActor @Sendable () -> Void) async throws
        -> UIAutomationActionResult<TypeResult>
    {
        let automationTarget = UIAutomationTarget.exactWindow(exactWindow)
        let captureReceipt = DesktopOperationPlan.CaptureReceipt(
            snapshotID: request.snapshotID,
            target: automationTarget)
        var payloadSummary: TypeActionPayloadSummary?
        var sequenceResolution: DesktopActionSequenceAccumulator.Resolution?

        let plan = try DesktopOperationPlan(
            verb: .type,
            selector: .coordinates(request.point),
            captureReceipt: captureReceipt,
            strategy: .synthOnly,
            prepare: {
                planDidEnter()
                try await self.pixelFocusPlanEntryHook()
                do {
                    let receiptPlan = try await self.pixelFocusReceiptPlanner(request.snapshotID)
                    let authority = try receiptPlan.receipt.requireCoordinateAuthority()
                    guard authority.target == exactWindow else {
                        throw SnapshotTargetReceiptPreDispatchError(.coordinateWindowMismatch)
                    }
                    guard authority.sourceBounds.contains(request.point),
                          exactWindow.bounds.contains(request.point)
                    else {
                        throw SnapshotTargetReceiptPreDispatchError(.coordinateBoundsMismatch)
                    }
                } catch let error as SnapshotTargetReceiptPreDispatchError {
                    throw error
                } catch is CancellationError {
                    throw PixelFocusSnapshotPreparationCancellation()
                } catch {
                    throw PixelFocusSnapshotPreparationFailure(causeDescription: error.localizedDescription)
                }
            },
            action: nil,
            synthesis: DesktopOperationPlan.SynthesisRoute {
                var sequence = DesktopActionSequenceAccumulator()
                do {
                    let focus = try await self.clickService.focusExactWindowPixelOwned(
                        at: request.point,
                        exactWindow: exactWindow)
                    guard let focusOutcome = focus.outcome else {
                        throw DesktopActionFailure.indeterminate(
                            delivery: .init(mechanism: .accessibilityValue, mode: .background),
                            evidence: .completionUnknown,
                            message: "Pixel focus returned no canonical action outcome.",
                            hint: "Observe the exact target before deciding whether to retry typing.")
                    }
                    sequence.record(.reportedOutcome(
                        focusOutcome,
                        defaultDispatchedUnitCount: .one))

                    let focusedElement = focus.payload
                    let validateFocusedElement: @MainActor @Sendable () async throws -> Void = {
                        try await deliveryValidator(focusedElement)
                    }
                    try await validateFocusedElement()
                    let typed = try await self.performSyntheticTypeActions(
                        request.actions,
                        cadence: request.cadence,
                        snapshotId: request.snapshotID,
                        targetProcessIdentifier: request.windowIdentity.ownerProcessIdentifier,
                        deliveryValidator: validateFocusedElement)
                    guard let typingUnits = DesktopActionOutcome.DispatchUnitCount(typed.result.keyPresses) else {
                        throw PeekabooError.invalidInput("Pixel-focus typing produced no keyboard input")
                    }
                    payloadSummary = typed
                    sequence.record(.dispatched(
                        route: .local,
                        delivery: automationTarget.keyboardDelivery,
                        unitCount: typingUnits))
                    let resolution = sequence.successResolution()
                    sequenceResolution = resolution
                    guard let outcome = resolution.outcome else {
                        throw DesktopActionFailure.indeterminate(
                            delivery: automationTarget.keyboardDelivery,
                            evidence: .completionUnknown,
                            unitCount: resolution.mutationDisposition.unitCount,
                            message: "Pixel-focus typing completed without a composable action outcome.",
                            hint: "Observe the exact target before deciding whether to retry.")
                    }
                    return outcome
                } catch is CancellationError {
                    if let failure = sequence.cancellationFailure(
                        fallbackRoute: .local,
                        message: "Pixel-focus typing was cancelled after dispatch began.",
                        hint: "Observe the exact target before deciding whether to retry.",
                        causeDescription: "Pixel-focus typing task cancelled")
                    {
                        throw failure
                    }
                    throw PixelFocusActionPreDispatchCancellation()
                } catch let error as InputDeliveryIndeterminateError {
                    throw sequence.failure(
                        combining: error.desktopActionFailure(delivery: automationTarget.keyboardDelivery),
                        message: "Pixel-focus typing stopped after a click or keyboard prefix was dispatched.",
                        hint: "Observe the exact target before deciding whether to retry.")
                } catch let failure as DesktopActionFailure {
                    throw sequence.failure(
                        combining: failure,
                        message: "Pixel-focus typing did not complete after its focus write.",
                        hint: "Observe the exact target before deciding whether to retry.")
                } catch {
                    guard sequence.mutationDisposition.mutationDispatched else {
                        if let peekabooError = error as? PeekabooError,
                           case .permissionDeniedAccessibility = peekabooError
                        {
                            throw PixelFocusActionPreDispatchFailure(
                                causeDescription: error.localizedDescription)
                        }
                        throw error
                    }
                    let leaf = DesktopActionFailure.preDispatchRefusal(
                        reason: .targetUnavailable,
                        message: error.localizedDescription)
                    throw sequence.failure(
                        combining: leaf,
                        message: "Pixel-focus typing could not prove its destination after focusing.",
                        hint: "Observe the exact target before deciding whether to retry.",
                        causeDescription: error.localizedDescription)
                }
            },
            finalize: self.operationFinalizer)

        _ = try await self.desktopOperationExecutor.executeWithTargetIdentity(plan)
        guard let payloadSummary, sequenceResolution != nil else {
            throw PeekabooError.operationError(message: "Pixel-focus typing produced no result")
        }
        return UIAutomationActionResult(
            payload: payloadSummary.result,
            outcome: sequenceResolution?.outcome,
            targetIdentity: DesktopTargetIdentity(exactWindow: exactWindow))
    }

    private static func plannedKeyPressCount(_ actions: [TypeAction]) -> Int {
        actions.reduce(into: 0) { count, action in
            switch action {
            case let .text(text): count += text.count
            case .key: count += 1
            case .clear: count += 2
            }
        }
    }
}
