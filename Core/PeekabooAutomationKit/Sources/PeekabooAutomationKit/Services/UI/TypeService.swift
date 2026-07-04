import AppKit
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import os.log
import PeekabooFoundation

/// Service for handling typing and text input operations
@MainActor
public final class TypeService {
    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "TypeService")
    let snapshotManager: any SnapshotManagerProtocol
    private let clickService: ClickService
    let cadenceRandom: any TypingCadenceRandomSource
    let inputPolicy: UIInputPolicy
    private let actionInputDriver: any ActionInputDriving
    private let syntheticInputDriver: any SyntheticInputDriving
    private let automationElementResolver: any AutomationElementResolving

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
        automationElementResolver: any AutomationElementResolving = AutomationElementResolver())
    {
        self.init(
            snapshotManager: snapshotManager,
            clickService: clickService,
            inputPolicy: inputPolicy,
            actionInputDriver: actionInputDriver,
            syntheticInputDriver: syntheticInputDriver,
            automationElementResolver: automationElementResolver,
            randomSource: SystemTypingCadenceRandomSource())
    }

    init(
        snapshotManager: (any SnapshotManagerProtocol)? = nil,
        clickService: ClickService? = nil,
        inputPolicy: UIInputPolicy = .currentBehavior,
        actionInputDriver: any ActionInputDriving = ActionInputDriver(),
        syntheticInputDriver: any SyntheticInputDriving = SyntheticInputDriver(),
        automationElementResolver: any AutomationElementResolving = AutomationElementResolver(),
        randomSource: any TypingCadenceRandomSource)
    {
        let manager = snapshotManager ?? SnapshotManager()
        self.snapshotManager = manager
        self.clickService = clickService ?? ClickService(
            snapshotManager: manager,
            inputPolicy: inputPolicy,
            actionInputDriver: actionInputDriver,
            syntheticInputDriver: syntheticInputDriver,
            automationElementResolver: automationElementResolver)
        self.inputPolicy = inputPolicy
        self.actionInputDriver = actionInputDriver
        self.syntheticInputDriver = syntheticInputDriver
        self.automationElementResolver = automationElementResolver
        self.cadenceRandom = randomSource
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
        self.logger
            .debug("Type requested - text: '\(text)', target: \(target ?? "current focus"), clear: \(clearExisting)")
        let bundleIdentifier = await self.bundleIdentifier(snapshotId: snapshotId)

        let result = try await UIInputDispatcher.run(
            verb: .type,
            strategy: self.inputPolicy.strategy(for: .type, bundleIdentifier: bundleIdentifier),
            bundleIdentifier: bundleIdentifier,
            action: {
                try await self.performActionType(
                    text: text,
                    target: target,
                    clearExisting: clearExisting,
                    snapshotId: snapshotId)
            },
            synth: {
                try await self.performSyntheticType(
                    text: text,
                    target: target,
                    clearExisting: clearExisting,
                    typingDelay: typingDelay,
                    snapshotId: snapshotId)
            })

        self.logger.debug("Type completed via \(result.path.rawValue, privacy: .public)")
        return result
    }

    private func performActionType(
        text: String,
        target: String?,
        clearExisting: Bool,
        snapshotId: String?) async throws -> ActionInputResult
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
        snapshotId: String?) async throws
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
                    try await self.clickService.click(
                        target: .elementId(elementId),
                        clickType: .single,
                        snapshotId: snapshotId)
                } else if let frame = elementFrame {
                    let center = CGPoint(x: frame.midX, y: frame.midY)
                    let adjusted = try await self.resolveAdjustedPoint(center, snapshotId: snapshotId)
                    try await self.clickService.click(
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
            try await self.clearCurrentField()
        }

        // Type the text
        try await self.typeTextWithDelay(text, delay: TimeInterval(typingDelay) / 1000.0)

        self.logger.debug("Successfully typed \(text.count) characters")
    }

    /// Type actions (advanced typing with special keys)
    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?) async throws -> TypeResult
    {
        try await self.typeActions(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            targetProcessIdentifier: nil)
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: pid_t?) async throws -> TypeResult
    {
        var result: TypeResult?
        _ = try await UIInputDispatcher.run(
            verb: .type,
            strategy: targetProcessIdentifier == nil ? self.inputPolicy.strategy(for: .type) : .synthOnly,
            action: nil,
            synth: {
                result = try await self.performSyntheticTypeActions(
                    actions,
                    cadence: cadence,
                    snapshotId: snapshotId,
                    targetProcessIdentifier: targetProcessIdentifier)
            })

        guard let result else {
            throw PeekabooError.operationError(message: "Type action execution did not produce a result")
        }
        return result
    }

    private func performSyntheticTypeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId _: String?,
        targetProcessIdentifier: pid_t?) async throws -> TypeResult
    {
        var totalChars = 0
        var keyPresses = 0
        var humanContext: HumanTypingContext?
        let fixedDelay = self.fixedDelaySeconds(for: cadence)

        self.logger.debug("Processing \(actions.count) type actions with cadence: \(cadence.logDescription)")

        for action in actions {
            switch action {
            case let .text(text):
                for character in text {
                    try await self.typeCharacter(character, targetProcessIdentifier: targetProcessIdentifier)
                    totalChars += 1
                    keyPresses += 1
                    try await self.sleepAfterKeystroke(
                        typedCharacter: character,
                        cadence: cadence,
                        fixedDelaySeconds: fixedDelay,
                        humanContext: &humanContext)
                }

            case let .key(key):
                try self.typeSpecialKey(key, targetProcessIdentifier: targetProcessIdentifier)
                keyPresses += 1
                try await self.sleepAfterKeystroke(
                    typedCharacter: nil,
                    cadence: cadence,
                    fixedDelaySeconds: fixedDelay,
                    humanContext: &humanContext)

            case .clear:
                try await self.clearCurrentField(targetProcessIdentifier: targetProcessIdentifier)
                keyPresses += 2 // Cmd+A and Delete
                try await self.sleepAfterKeystroke(
                    typedCharacter: nil,
                    cadence: cadence,
                    fixedDelaySeconds: fixedDelay,
                    humanContext: &humanContext)
            }
        }

        return TypeResult(
            totalCharacters: totalChars,
            keyPresses: keyPresses)
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

    private func clearCurrentField(targetProcessIdentifier: pid_t? = nil) async throws {
        self.logger.debug("Clearing current field")

        if let targetProcessIdentifier {
            if try BackgroundInputDriver.replaceFocusedText(
                with: "",
                targetProcessIdentifier: targetProcessIdentifier)
            {
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                return
            }

            try BackgroundInputDriver.tapKey(
                keyCode: 0x00,
                modifiers: .maskCommand,
                targetProcessIdentifier: targetProcessIdentifier)
        } else {
            try self.syntheticInputDriver.hotkey(keys: ["cmd", "a"], holdDuration: 0.1)
        }
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        if let targetProcessIdentifier {
            try BackgroundInputDriver.tapKey(
                keyCode: TypeServiceSpecialKeyMapping.keyCode(for: .delete),
                targetProcessIdentifier: targetProcessIdentifier)
        } else {
            try self.syntheticInputDriver.tapKey(.delete, modifiers: [])
        }
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
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
            if try BackgroundInputDriver.insertTextIntoFocusedText(
                String(char),
                targetProcessIdentifier: targetProcessIdentifier)
            {
                return
            }
            try BackgroundInputDriver.typeCharacter(char, targetProcessIdentifier: targetProcessIdentifier)
        } else {
            try self.syntheticInputDriver.type(String(char), delayPerCharacter: 0)
        }
    }
}
