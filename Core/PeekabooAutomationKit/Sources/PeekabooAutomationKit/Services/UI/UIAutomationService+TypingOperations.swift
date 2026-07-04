import ApplicationServices
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
        self.logger.debug("Delegating type to TypeService")
        // For targeted typing the resolved destination element is
        // authoritative; focus sampling can miss it entirely (the target is
        // focused only mid-flow, and a trailing {return} can move focus away
        // again). Untargeted typing goes to the current focus, so sample that
        // before typing for the same trailing-submit reason.
        let secureBeforeTyping: Bool = if let target {
            await self.typeService.typingTargetIsSecureField(target: target, snapshotId: snapshotId)
        } else {
            Self.focusedElementIsSecureField()
        }
        _ = try await self.normalizingSnapshotErrors {
            try await self.typeService.type(
                text: text,
                target: target,
                clearExisting: clearExisting,
                typingDelay: typingDelay,
                snapshotId: snapshotId)
        }

        await self.visualizeTyping(
            keys: Array(text).map { String($0) },
            cadence: .fixed(milliseconds: typingDelay),
            typedIntoSecureField: secureBeforeTyping)
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?) async throws -> TypeResult
    {
        self.logger.debug("Delegating typeActions to TypeService")
        let secureBeforeTyping = Self.focusedElementIsSecureField()
        let result = try await self.normalizingSnapshotErrors {
            try await self.typeService.typeActions(actions, cadence: cadence, snapshotId: snapshotId)
        }
        await self.visualizeTypeActions(actions, cadence: cadence, typedIntoSecureField: secureBeforeTyping)
        return result
    }

    public func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: pid_t) async throws -> TypeResult
    {
        self.logger.debug("Delegating targeted typeActions to TypeService")
        // Background typing lands in the target app's focused element, not the
        // global focus, so the secure-field samples are scoped to that PID.
        let secureBeforeTyping = Self.focusedElementIsSecureField(processIdentifier: targetProcessIdentifier)
        let result = try await self.normalizingSnapshotErrors {
            try await self.typeService.typeActions(
                actions,
                cadence: cadence,
                snapshotId: snapshotId,
                targetProcessIdentifier: targetProcessIdentifier)
        }
        await self.visualizeTypeActions(
            actions,
            cadence: cadence,
            typedIntoSecureField: secureBeforeTyping,
            targetProcessIdentifier: targetProcessIdentifier)
        return result
    }

    // MARK: - Typing Visualization Helpers

    func visualizeTypeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        typedIntoSecureField: Bool = false,
        targetProcessIdentifier: pid_t? = nil) async
    {
        let keys = self.keySequence(from: actions)
        await self.visualizeTyping(
            keys: keys,
            cadence: cadence,
            typedIntoSecureField: typedIntoSecureField,
            targetProcessIdentifier: targetProcessIdentifier)
    }

    func visualizeTyping(
        keys: [String],
        cadence: TypingCadence,
        typedIntoSecureField: Bool = false,
        targetProcessIdentifier: pid_t? = nil) async
    {
        guard !keys.isEmpty else { return }
        // Typed text shows verbatim in the caption; only password fields mask.
        // The post-typing sample can miss a secure field when the last key
        // (e.g. {return}) submits and moves focus, so callers also pass the
        // pre-typing sample and either one masks. Both samples are scoped to
        // the process that received the keys when one is specified.
        let masksTypedText = typedIntoSecureField
            || Self.focusedElementIsSecureField(processIdentifier: targetProcessIdentifier)
        _ = await self.feedbackClient.showTypingFeedback(
            keys: keys,
            duration: 2.0,
            cadence: cadence,
            masksTypedText: masksTypedText)
    }

    /// Best-effort check whether keystrokes land in a secure (password)
    /// field, so the caption masks them. Samples the focused element of the
    /// delivery scope: the target app for background typing, otherwise the
    /// system-wide focus that synthetic keystrokes go to. Direct value writes
    /// never reach secure fields — the action driver refuses them
    /// (`secureValueNotAllowed`) and falls back to focus-based typing.
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

        let element = unsafeBitCast(focused, to: AXUIElement.self)
        func stringAttribute(_ name: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value as? String
        }

        return stringAttribute(kAXRoleAttribute as String) == "AXSecureTextField"
            || stringAttribute(kAXSubroleAttribute as String) == "AXSecureTextField"
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
