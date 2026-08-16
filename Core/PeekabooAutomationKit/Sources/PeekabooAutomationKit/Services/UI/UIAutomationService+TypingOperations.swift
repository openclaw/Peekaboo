import Foundation
import PeekabooFoundation

extension UIAutomationService {
    // MARK: - Typing Operations

    /**
     * Perform intelligent text input with focus management and visual feedback.
     *
     * This method handles text input operations with automatic focus management, existing
     * content clearing, and configurable typing speeds. It supports both targeted typing
     * (to specific elements) and global typing (to currently focused element).
     *
     * - Parameters:
     *   - text: The text to type
     *   - target: Optional element ID to type into (types to focused element if nil)
     *   - clearExisting: Whether to clear existing text before typing
     *   - typingDelay: Delay between keystrokes in milliseconds (for realistic typing)
     *   - snapshotId: Optional snapshot ID for element resolution
     * - Throws: `PeekabooError` if target element cannot be found or typing fails
     *
     * ## Focus Management
     * - **Targeted Typing**: Automatically focuses the specified element before typing
     * - **Global Typing**: Types into whatever element currently has focus
     * - **Focus Validation**: Ensures element can accept text input before proceeding
     *
     * ## Text Handling
     * - **Unicode Support**: Full Unicode character support including emoji
     * - **Special Characters**: Handles newlines, tabs, and special key combinations
     * - **Content Clearing**: Optional clearing of existing content via Cmd+A, Delete
     * - **Typing Simulation**: Realistic typing with configurable delays between characters
     *
     * ## Visual Feedback
     * When visualizer is connected, displays:
     * - Character-by-character typing indicators
     * - Typing speed visualization
     * - Target element highlighting
     * - Focus transition animations
     *
     * ## Performance
     * - **Focus Resolution**: 20-100ms for element focusing
     * - **Character Input**: Configurable delay (0-1000ms) per character
     * - **Content Clearing**: 50-150ms for Cmd+A, Delete sequence
     *
     * ## Example
     * ```swift
     * // Type into specific element with clearing
     * try await automation.type(
     *     text: "Hello World!",
     *     target: detectedElement.id,
     *     clearExisting: true,
     *     typingDelay: 50,
     *     snapshotId: "snapshot_123"
     * )
     *
     * // Type into currently focused element
     * try await automation.type(
     *     text: "Quick text",
     *     target: nil,
     *     clearExisting: false,
     *     typingDelay: 0,
     *     snapshotId: nil
     * )
     *
     * // Type with realistic human-like speed
     * try await automation.type(
     *     text: "Realistic typing simulation",
     *     target: "searchField",
     *     clearExisting: true,
     *     typingDelay: 100,
     *     snapshotId: "snapshot_123"
     * )
     * ```
     *
     * - Important: Requires Accessibility permission for element-based typing
     * - Note: Typing delay of 0 results in instant text insertion
     */
    public func type(
        text: String,
        target: String?,
        clearExisting: Bool,
        typingDelay: Int,
        snapshotId: String?) async throws
    {
        _ = try await self.typeWithOutcome(
            text: text,
            target: target,
            clearExisting: clearExisting,
            typingDelay: typingDelay,
            snapshotId: snapshotId)
    }

    public func typeWithOutcome(
        text: String,
        target: String?,
        clearExisting: Bool,
        typingDelay: Int,
        snapshotId: String?) async throws -> UIAutomationActionResult<Void>
    {
        self.logger.debug("Delegating type to TypeService")
        var visualizerTarget: VisualizerTargetWindow?
        let summary = try await self.normalizingSnapshotErrors {
            try await self.typeService.typeTrackingSecureInput(
                text: text,
                target: target,
                clearExisting: clearExisting,
                typingDelay: typingDelay,
                snapshotId: snapshotId,
                lanePreparation: {
                    visualizerTarget = await self.visualizerTargetWindow(snapshotId: snapshotId)
                },
                laneCompletion: { _, typedIntoSecureField in
                    await self.visualizeTyping(
                        keys: Array(text).map { String($0) },
                        cadence: .fixed(milliseconds: typingDelay),
                        typedIntoSecureField: typedIntoSecureField,
                        visualizerTarget: visualizerTarget)
                })
        }
        return UIAutomationActionResult(payload: (), outcome: summary.result.outcome)
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?) async throws -> TypeResult
    {
        try await self.typeActionsWithOutcome(
            actions,
            cadence: cadence,
            snapshotId: snapshotId).payload
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?) async throws -> UIAutomationActionResult<TypeResult>
    {
        self.logger.debug("Delegating typeActions to TypeService")
        var visualizerTarget: VisualizerTargetWindow?
        let summary = try await self.normalizingSnapshotErrors {
            try await self.typeService.typeActionsTrackingSecureInput(
                actions,
                cadence: cadence,
                snapshotId: snapshotId,
                automationTarget: .foreground,
                lanePreparation: {
                    visualizerTarget = await self.visualizerTargetWindow(snapshotId: snapshotId)
                },
                laneCompletion: { summary in
                    await self.visualizeTypeActions(
                        actions,
                        cadence: cadence,
                        typedIntoSecureField: summary.typedIntoSecureField,
                        visualizerTarget: visualizerTarget)
                })
        }
        return UIAutomationActionResult(
            payload: summary.result,
            outcome: summary.executionResult.outcome)
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> TypeResult
    {
        try await self.typeActionsWithOutcome(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds).payload
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<TypeResult>
    {
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: expectedWindowIdentity,
            bounds: expectedWindowBounds)
        let automationTarget = UIAutomationTarget.exactWindow(exactWindow)
        let validator: @MainActor @Sendable () async throws -> Void = {
            try await self.requireExactWindowKeyboardFocus(
                expectedWindowIdentity: expectedWindowIdentity,
                expectedWindowBounds: expectedWindowBounds)
        }
        let summary = try await self.normalizingSnapshotErrors {
            try await self.typeService.typeActionsTrackingSecureInput(
                actions,
                cadence: cadence,
                snapshotId: snapshotId,
                automationTarget: automationTarget,
                deliveryValidator: validator)
        }
        return UIAutomationActionResult(
            payload: summary.result,
            outcome: summary.executionResult.outcome,
            targetIdentity: DesktopTargetIdentity(exactWindow: exactWindow))
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        target: ExactWindowKeyboardTarget) async throws -> TypeResult
    {
        try await self.typeActionsWithOutcome(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            target: target).payload
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        target: ExactWindowKeyboardTarget) async throws -> UIAutomationActionResult<TypeResult>
    {
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: target.windowIdentity,
            bounds: target.windowBounds,
            focusedElement: target.focusedElement)
        let automationTarget = UIAutomationTarget.exactWindow(exactWindow)
        let validator: @MainActor @Sendable () async throws -> Void = {
            try await self.requireExactWindowKeyboardFocus(
                expectedWindowIdentity: target.windowIdentity,
                expectedWindowBounds: target.windowBounds,
                expectedFocusedElement: target.focusedElement)
        }
        let summary = try await self.normalizingSnapshotErrors {
            try await self.typeService.typeActionsTrackingSecureInput(
                actions,
                cadence: cadence,
                snapshotId: snapshotId,
                automationTarget: automationTarget,
                deliveryValidator: validator)
        }
        return UIAutomationActionResult(
            payload: summary.result,
            outcome: summary.executionResult.outcome,
            targetIdentity: DesktopTargetIdentity(exactWindow: exactWindow))
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws -> TypeResult
    {
        try await self.typeActionsWithOutcome(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier).payload
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws -> UIAutomationActionResult<TypeResult>
    {
        self.logger.debug("Delegating targeted typeActions to TypeService")
        let automationTarget: UIAutomationTarget = try .process(UIAutomationTarget.Process(
            processIdentifier: targetProcessIdentifier))
        let summary = try await self.normalizingSnapshotErrors {
            try await self.typeService.typeActionsTrackingSecureInput(
                actions,
                cadence: cadence,
                snapshotId: snapshotId,
                automationTarget: automationTarget)
        }
        await self.visualizeTypeActions(
            actions,
            cadence: cadence,
            typedIntoSecureField: summary.typedIntoSecureField,
            targetProcessIdentifier: targetProcessIdentifier)
        return UIAutomationActionResult(
            payload: summary.result,
            outcome: summary.executionResult.outcome)
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> TypeResult
    {
        try await self.typeActionsWithOutcome(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            expectedProcessIdentity: expectedProcessIdentity).payload
    }

    public func typeActionsWithOutcome(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<TypeResult>
    {
        let processTarget = try UIAutomationTarget.Process(
            processIdentifier: expectedProcessIdentity.processIdentifier,
            identity: expectedProcessIdentity)
        let automationTarget = UIAutomationTarget.process(processTarget)
        let targetIdentity = try DesktopTargetIdentity(processIdentity: expectedProcessIdentity)
        let validator: @MainActor @Sendable () async throws -> Void = {
            guard self.processStartIdentityProvider(expectedProcessIdentity.processIdentifier) ==
                expectedProcessIdentity.processStartIdentity
            else {
                throw PeekabooError.invalidInput(
                    "Background typing target process exited or changed process generation")
            }
        }
        let summary = try await self.normalizingSnapshotErrors {
            try await self.typeService.typeActionsTrackingSecureInput(
                actions,
                cadence: cadence,
                snapshotId: snapshotId,
                automationTarget: automationTarget,
                deliveryValidator: validator)
        }
        return UIAutomationActionResult(
            payload: summary.result,
            outcome: summary.executionResult.outcome,
            targetIdentity: targetIdentity)
    }

    // MARK: - Typing Visualization Helpers

    func visualizeTypeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        typedIntoSecureField: Bool = false,
        targetProcessIdentifier: pid_t? = nil,
        visualizerTarget: VisualizerTargetWindow? = nil) async
    {
        let keys = self.keySequence(from: actions)
        await self.visualizeTyping(
            keys: keys,
            cadence: cadence,
            typedIntoSecureField: typedIntoSecureField,
            targetProcessIdentifier: targetProcessIdentifier,
            visualizerTarget: visualizerTarget)
    }

    func visualizeTyping(
        keys: [String],
        cadence: TypingCadence,
        typedIntoSecureField: Bool = false,
        targetProcessIdentifier: pid_t? = nil,
        visualizerTarget: VisualizerTargetWindow? = nil) async
    {
        guard !keys.isEmpty else { return }
        // Targeted typing (including press and background text paste) is intentionally invisible.
        // The visualizer overlay is desktop-global even though the input is routed to one process.
        guard targetProcessIdentifier == nil else { return }
        // Typed text shows verbatim in the caption; only password fields mask.
        // Type-action callers sample each text segment at delivery time; the
        // post-typing sample remains a final safety net for direct text entry.
        let masksTypedText = typedIntoSecureField
            || TypeService.focusedElementIsSecureField(processIdentifier: targetProcessIdentifier)
        _ = await self.feedbackClient.showTypingFeedback(
            keys: keys,
            duration: 2.0,
            cadence: cadence,
            masksTypedText: masksTypedText,
            target: visualizerTarget ?? VisualizerTargetWindowResolver.frontmostWindow())
    }

    private func keySequence(from actions: [TypeAction]) -> [String] {
        var sequence: [String] = []

        for action in actions {
            switch action {
            case let .text(text):
                sequence.append(contentsOf: text.map { String($0) })
            case let .key(key):
                sequence.append("{\(key.rawValue)}")
            case .clear:
                sequence.append(contentsOf: ["{cmd+a}", "{delete}"])
            }
        }

        return sequence
    }
}
