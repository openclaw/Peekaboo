import ApplicationServices
@preconcurrency import AXorcist
import CoreGraphics
import Darwin
import Foundation
import os.log
import PeekabooFoundation

/// Background input that targets a process directly without focusing it or moving the cursor.
///
/// Keyboard input is delivered as pid-routed CGEvents. Pointer clicks are delivered through
/// accessibility actions instead: positioned pid-routed mouse events are broken on modern macOS —
/// the `windowID` routing field (0x33) is required for the event to be delivered at all, and its
/// presence makes the WindowServer discard the event location, landing every click at the target
/// window's top-left corner. See `click(at:button:count:targetProcessIdentifier:targetWindowID:)`.
enum BackgroundInputDriver {
    private static let logger = Logger(subsystem: "boo.peekaboo.core", category: "BackgroundInputDriver")

    struct MouseWindowRouteCandidate: Equatable {
        let windowID: CGWindowID
        let processIdentifier: pid_t
        let layer: Int
        let bounds: CGRect
    }

    struct KeyboardEventPlan {
        let modifierKeyDownEvents: [CGEvent]
        let primaryKeyDownEvent: CGEvent
        let primaryKeyUpEvent: CGEvent
        let modifierKeyUpEvents: [CGEvent]
    }

    /// How a background positional click is delivered once the AX element chain is resolved.
    enum PositionalClickAction: Equatable {
        case press
        case showMenu
        case focus
    }

    /// Deliver a positional click to a background process via accessibility.
    ///
    /// Synthetic positioned mouse events are intentionally not used: `SLEventPostToPid` /
    /// `CGEvent.postToPid` require the `windowID` field for delivery, and stamping it makes macOS
    /// ignore the event location entirely (every click lands at the window's top-left corner).
    /// The element at `point` is hit-tested via `AXUIElementCopyElementAtPosition` and its press
    /// (or show-menu) action is invoked instead, which is position-faithful and background-safe.
    @MainActor
    static func click(
        at point: CGPoint,
        button: MouseButton,
        count: Int,
        targetProcessIdentifier: pid_t,
        targetWindowID: CGWindowID? = nil) async throws
    {
        guard targetProcessIdentifier > 0, self.isProcessAlive(targetProcessIdentifier) else {
            throw PeekabooError.invalidInput("Target process identifier is not running: \(targetProcessIdentifier)")
        }

        guard count == 1 else {
            throw PeekabooError.serviceUnavailable(self.doubleClickUnsupportedMessage)
        }
        guard button != .middle else {
            throw PeekabooError.serviceUnavailable(self.middleClickUnsupportedMessage)
        }

        // Exact-window pinning still guards against stale windows, PID reuse, and moved points.
        _ = try self.resolveTargetWindowID(
            at: point,
            targetProcessIdentifier: targetProcessIdentifier,
            exactWindowID: targetWindowID,
            candidates: self.mouseWindowRouteCandidates(exactWindowID: targetWindowID))

        guard AXIsProcessTrusted() else {
            throw PeekabooError.permissionDeniedAccessibility
        }

        let candidates = self.hitTestCandidates(at: point, targetProcessIdentifier: targetProcessIdentifier)
        guard let resolved = Self.positionalClickTarget(inCandidates: candidates, at: point, button: button) else {
            throw PeekabooError.serviceUnavailable(
                Self.noActionableElementMessage(at: point, targetProcessIdentifier: targetProcessIdentifier))
        }

        // AX hit-testing is only PID-scoped: if an exact window was pinned, verify the element we
        // are about to press actually lives in that window. Another window of the same process can
        // overlap the point, in which case the hit resolves to the frontmost window's element and
        // pressing it would silently click the wrong window.
        if let targetWindowID {
            try self.assertBelongsToTargetWindow(resolved.element, targetWindowID: targetWindowID, at: point)
        }

        switch resolved.action {
        case .press:
            try await self.performDetachedAction(
                AXActionNames.kAXPressAction,
                on: resolved.element,
                gracePeriod: DetachedAXActionRunner.pressGracePeriod)
        case .showMenu:
            try await self.performDetachedAction(
                AXActionNames.kAXShowMenuAction,
                on: resolved.element,
                gracePeriod: DetachedAXActionRunner.showMenuGracePeriod)
        case .focus:
            try resolved.element.setAutomationFocused(true)
        }
    }

    /// Picks the element that should receive a positional background click.
    ///
    /// `candidates` is ordered: the hit-tested element first, then its descendants, then its
    /// ancestors (see `hitTestCandidates`). The hit-test element is authoritative — macOS returned
    /// it for this exact point — so it is never rejected on frame grounds; every other candidate
    /// must still contain the point. The first enabled candidate that supports the required action
    /// wins. SwiftUI hit-tests can land on a non-pressable container whose pressable target is a
    /// descendant, so descendants are searched before ancestors. Left clicks on text inputs (which
    /// have no `AXPress`) fall back to focusing the element, mirroring `ActionInputDriver`.
    @MainActor
    static func positionalClickTarget(
        inCandidates candidates: [any AutomationElementRepresenting],
        at point: CGPoint,
        button: MouseButton) -> (element: any AutomationElementRepresenting, action: PositionalClickAction)?
    {
        guard let hit = candidates.first else { return nil }
        // Trust the hit-test element regardless of its reported frame (coordinate-space quirks must
        // not veto the element macOS resolved for the point); spatially filter the rest.
        let spatiallyValid = [hit] + candidates.dropFirst().filter { element in
            element.frame?.contains(point) == true
        }

        let requiredAction = button == .right ? AXActionNames.kAXShowMenuAction : AXActionNames.kAXPressAction
        if let actionable = spatiallyValid.first(where: {
            $0.isEnabled &&
                $0.supportsAction(requiredAction) &&
                (button == .right || !self.nonPressableContainerRoles.contains($0.role ?? ""))
        }) {
            let role = actionable.role ?? "<none>"
            let frame = String(describing: actionable.frame)
            self.logger.debug(
                """
                Resolved background positional click to role=\(role, privacy: .public) \
                action=\(requiredAction, privacy: .public) frame=\(frame, privacy: .public)
                """)
            return (actionable, button == .right ? .showMenu : .press)
        }

        guard button == .left else { return nil }
        let focusable = spatiallyValid.first(where: self.canFocusForPositionalClick)
        if let focusable {
            let role = focusable.role ?? "<none>"
            let frame = String(describing: focusable.frame)
            self.logger.debug(
                """
                Resolved background positional click to role=\(role, privacy: .public) \
                action=focus frame=\(frame, privacy: .public)
                """)
            return (focusable, .focus)
        }
        self.logger.debug("No actionable background positional click target resolved")
        return nil
    }

    /// Coordinate clicks may focus text-entry controls that expose no press action. Keep this
    /// narrower than element-targeted action input: Chromium marks full-page AXGroup containers
    /// value/focus-settable, and focusing those containers is not a delivered click.
    @MainActor
    private static func canFocusForPositionalClick(_ element: any AutomationElementRepresenting) -> Bool {
        guard element.isFocusedSettable else { return false }
        switch element.role {
        case "AXTextField", "AXTextArea", "AXComboBox":
            return true
        default:
            return element.subrole == "AXSearchField"
        }
    }

    /// Gathers positional-click candidates for `point`, ordered hit → descendants → ancestors.
    ///
    /// The hit-test element is where macOS says the point lands. Descendants are searched next
    /// because SwiftUI frequently hit-tests to a container whose pressable button is nested inside
    /// it; ancestors are the last resort. All three sets are bounded so a deep tree cannot stall
    /// the click.
    /// Rejects a resolved element that does not belong to the pinned `targetWindowID`.
    ///
    /// `_AXUIElementGetWindow` (via `AXWindowResolver`) returns the element's containing window in
    /// the same CGWindowID namespace as the pinning selector. A `nil` window id means the element
    /// exposes no window (or the lookup failed); for a pinned exact-window click that is treated as
    /// a mismatch so the click is never delivered to an unverified window.
    @MainActor
    private static func assertBelongsToTargetWindow(
        _ element: any AutomationElementRepresenting,
        targetWindowID: CGWindowID,
        at point: CGPoint) throws
    {
        guard let axElement = element.underlyingAXElement else {
            // In-memory elements (tests) carry no AX identity and cannot be window-verified.
            return
        }
        guard AXWindowResolver().windowID(from: axElement) == targetWindowID else {
            throw PeekabooError.serviceUnavailable(
                Self.occludedWindowMessage(at: point, targetWindowID: targetWindowID))
        }
    }

    @MainActor
    private static func hitTestCandidates(
        at point: CGPoint,
        targetProcessIdentifier: pid_t) -> [any AutomationElementRepresenting]
    {
        guard let hit = Element.elementAtPoint(point, pid: targetProcessIdentifier) else {
            return []
        }

        var candidates: [any AutomationElementRepresenting] = [AutomationElement(hit)]
        candidates.append(contentsOf: self.descendantsBreadthFirst(of: hit, maxVisited: 256, maxDepth: 8))

        var current = hit.parent()
        var remainingAncestors = 8
        while let element = current, remainingAncestors > 0 {
            candidates.append(AutomationElement(element))
            current = element.parent()
            remainingAncestors -= 1
        }
        return candidates
    }

    @MainActor
    private static func descendantsBreadthFirst(
        of root: Element,
        maxVisited: Int,
        maxDepth: Int) -> [any AutomationElementRepresenting]
    {
        var result: [any AutomationElementRepresenting] = []
        var queue: [(element: Element, depth: Int)] = (root.children() ?? []).map { ($0, 1) }
        var visited = 0
        while !queue.isEmpty, visited < maxVisited {
            let (element, depth) = queue.removeFirst()
            visited += 1
            result.append(AutomationElement(element))
            if depth < maxDepth {
                queue.append(contentsOf: (element.children() ?? []).map { ($0, depth + 1) })
            }
        }
        return result
    }

    @MainActor
    private static func performDetachedAction(
        _ actionName: String,
        on element: any AutomationElementRepresenting,
        gracePeriod: TimeInterval) async throws
    {
        guard let axElement = element.underlyingAXElement else {
            try element.performAutomationAction(actionName)
            return
        }

        let outcome = await DetachedAXActionRunner.perform(
            action: actionName,
            on: axElement,
            gracePeriod: gracePeriod)
        try self.validateDetachedActionOutcome(outcome, actionName: actionName)
    }

    static func validateDetachedActionOutcome(
        _ outcome: DetachedAXActionOutcome,
        actionName: String) throws
    {
        switch outcome {
        case .completed(.success):
            return
        case .stillRunning where actionName == "AXPress":
            throw PeekabooError.serviceUnavailable(self.unverifiedPressMessage)
        case .stillRunning:
            return
        case let .completed(axError):
            throw ActionInputDriver.classify(axError)
        }
    }

    static func type(
        _ text: String,
        delayPerCharacter: TimeInterval,
        targetProcessIdentifier: pid_t) throws
    {
        try self.validateTarget(targetProcessIdentifier)

        for character in text {
            try self.typeCharacter(character, targetProcessIdentifier: targetProcessIdentifier)
            if delayPerCharacter > 0 {
                Thread.sleep(forTimeInterval: delayPerCharacter)
            }
        }
    }

    static func typeCharacter(_ character: Character, targetProcessIdentifier: pid_t) throws {
        try self.validateTarget(targetProcessIdentifier)

        if let stroke = self.keyboardStroke(for: character) {
            try self.postKeyboardStroke(stroke, targetProcessIdentifier: targetProcessIdentifier)
            return
        }

        try self.postUnicodeCharacter(character, targetProcessIdentifier: targetProcessIdentifier)
    }

    static func tapKey(
        keyCode: CGKeyCode,
        modifiers: CGEventFlags = [],
        targetProcessIdentifier: pid_t) throws
    {
        try self.validateTarget(targetProcessIdentifier)
        try self.postKeyboardStroke(
            (keyCode: keyCode, flags: modifiers),
            targetProcessIdentifier: targetProcessIdentifier)
    }

    static func postEvent(_ event: CGEvent, to pid: pid_t) {
        self.post(event, to: pid)
    }

    @discardableResult
    static func replaceFocusedText(
        with text: String,
        targetProcessIdentifier: pid_t) throws -> Bool
    {
        try self.validateLiveTarget(targetProcessIdentifier)
        guard let element = try self.focusedEditableTextElement(targetProcessIdentifier: targetProcessIdentifier) else {
            return false
        }
        guard try self.setText(text, on: element) else {
            return false
        }
        self.setSelectedTextRange(CFRange(location: text.utf16.count, length: 0), on: element)
        return true
    }

    @discardableResult
    static func insertTextIntoFocusedText(
        _ text: String,
        targetProcessIdentifier: pid_t) throws -> Bool
    {
        try self.validateLiveTarget(targetProcessIdentifier)
        guard let element = try self.focusedEditableTextElement(targetProcessIdentifier: targetProcessIdentifier),
              let currentText = try self.textValue(from: element)
        else {
            return false
        }

        let selectedRange = self.selectedTextRange(from: element)
        let edit = self.textByReplacingSelection(in: currentText, selection: selectedRange, replacement: text)
        guard try self.setText(edit.text, on: element) else {
            return false
        }
        self.setSelectedTextRange(CFRange(location: edit.cursorLocation, length: 0), on: element)
        return true
    }

    @discardableResult
    static func performFocusedTextKey(
        _ key: PeekabooFoundation.SpecialKey,
        targetProcessIdentifier: pid_t) throws -> Bool
    {
        try self.validateLiveTarget(targetProcessIdentifier)
        guard let element = try self.focusedEditableTextElement(targetProcessIdentifier: targetProcessIdentifier),
              let currentText = try self.textValue(from: element)
        else {
            return false
        }

        let textLength = currentText.utf16.count
        let selection = self.clampedSelection(self.selectedTextRange(from: element), textLength: textLength)

        switch key {
        case .leftArrow:
            let location = self.cursorLocationMovingLeft(from: selection, in: currentText)
            self.setSelectedTextRange(CFRange(location: location, length: 0), on: element)
            return true

        case .rightArrow:
            let location = self.cursorLocationMovingRight(from: selection, in: currentText)
            self.setSelectedTextRange(CFRange(location: location, length: 0), on: element)
            return true

        case .home:
            self.setSelectedTextRange(CFRange(location: 0, length: 0), on: element)
            return true

        case .end:
            self.setSelectedTextRange(CFRange(location: textLength, length: 0), on: element)
            return true

        case .delete:
            guard let editRange = self.deletionRangeBeforeSelection(selection, in: currentText) else {
                return true
            }
            let edit = self.textByReplacingSelection(in: currentText, selection: editRange, replacement: "")
            guard try self.setText(edit.text, on: element) else { return false }
            self.setSelectedTextRange(CFRange(location: edit.cursorLocation, length: 0), on: element)
            return true

        case .forwardDelete:
            guard let editRange = self.deletionRangeAfterSelection(selection, in: currentText) else {
                return true
            }
            let edit = self.textByReplacingSelection(in: currentText, selection: editRange, replacement: "")
            guard try self.setText(edit.text, on: element) else { return false }
            self.setSelectedTextRange(CFRange(location: edit.cursorLocation, length: 0), on: element)
            return true

        case .space:
            let edit = self.textByReplacingSelection(in: currentText, selection: selection, replacement: " ")
            guard try self.setText(edit.text, on: element) else { return false }
            self.setSelectedTextRange(CFRange(location: edit.cursorLocation, length: 0), on: element)
            return true

        default:
            return false
        }
    }

    @discardableResult
    static func performFocusedTextHotkey(
        primaryKey: String,
        modifierFlags: CGEventFlags,
        targetProcessIdentifier: pid_t) throws -> Bool
    {
        try self.validateLiveTarget(targetProcessIdentifier)
        guard modifierFlags == .maskCommand,
              primaryKey == "a",
              let element = try self.focusedEditableTextElement(targetProcessIdentifier: targetProcessIdentifier),
              let currentText = try self.textValue(from: element)
        else {
            return false
        }

        self.setSelectedTextRange(CFRange(location: 0, length: currentText.utf16.count), on: element)
        return true
    }

    private static func post(_ event: CGEvent, to pid: pid_t) {
        if !SkyLightPerPidEventPost.post(event, to: pid) {
            event.postToPid(pid)
        }
    }

    private static func validateTarget(_ targetProcessIdentifier: pid_t) throws {
        guard CGPreflightPostEventAccess() else {
            throw PeekabooError.permissionDeniedEventSynthesizing
        }

        try self.validateLiveTarget(targetProcessIdentifier)
    }

    private static func validateLiveTarget(_ targetProcessIdentifier: pid_t) throws {
        guard targetProcessIdentifier > 0, self.isProcessAlive(targetProcessIdentifier) else {
            throw PeekabooError.invalidInput("Target process identifier is not running: \(targetProcessIdentifier)")
        }
    }

    private static func postKeyboardStroke(
        _ stroke: (keyCode: CGKeyCode, flags: CGEventFlags),
        targetProcessIdentifier: pid_t) throws
    {
        let plan = try self.keyboardEventPlan(
            keyCode: stroke.keyCode,
            flags: stroke.flags,
            targetProcessIdentifier: targetProcessIdentifier)

        for event in plan.modifierKeyDownEvents {
            self.post(event, to: targetProcessIdentifier)
            usleep(1000)
        }

        self.post(plan.primaryKeyDownEvent, to: targetProcessIdentifier)
        usleep(1000)
        self.post(plan.primaryKeyUpEvent, to: targetProcessIdentifier)

        for event in plan.modifierKeyUpEvents {
            usleep(1000)
            self.post(event, to: targetProcessIdentifier)
        }
    }

    static func keyboardEventPlan(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        targetProcessIdentifier: pid_t) throws -> KeyboardEventPlan
    {
        let source = CGEventSource(stateID: .hidSystemState)
        let modifiers = self.modifierKeys(for: flags)
        var activeFlags: CGEventFlags = []

        let modifierDownEvents = try modifiers.map { modifier in
            activeFlags.insert(modifier.flag)
            return try self.makeKeyboardEvent(
                keyCode: modifier.keyCode,
                keyDown: true,
                flags: activeFlags,
                source: source,
                targetProcessIdentifier: targetProcessIdentifier)
        }

        let primaryKeyDownEvent = try self.makeKeyboardEvent(
            keyCode: keyCode,
            keyDown: true,
            flags: flags,
            source: source,
            targetProcessIdentifier: targetProcessIdentifier)
        let primaryKeyUpEvent = try self.makeKeyboardEvent(
            keyCode: keyCode,
            keyDown: false,
            flags: flags,
            source: source,
            targetProcessIdentifier: targetProcessIdentifier)

        let modifierUpEvents = try modifiers.reversed().map { modifier in
            activeFlags.remove(modifier.flag)
            return try self.makeKeyboardEvent(
                keyCode: modifier.keyCode,
                keyDown: false,
                flags: activeFlags,
                source: source,
                targetProcessIdentifier: targetProcessIdentifier)
        }

        return KeyboardEventPlan(
            modifierKeyDownEvents: modifierDownEvents,
            primaryKeyDownEvent: primaryKeyDownEvent,
            primaryKeyUpEvent: primaryKeyUpEvent,
            modifierKeyUpEvents: modifierUpEvents)
    }

    private static func makeKeyboardEvent(
        keyCode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags,
        source: CGEventSource?,
        targetProcessIdentifier: pid_t) throws -> CGEvent
    {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            throw PeekabooError.operationError(message: "Failed to create background keyboard events")
        }

        event.flags = flags
        self.stampKeyboardRoutingFields(on: event, targetProcessIdentifier: targetProcessIdentifier)
        return event
    }

    private static func modifierKeys(for flags: CGEventFlags) -> [(keyCode: CGKeyCode, flag: CGEventFlags)] {
        var modifiers: [(keyCode: CGKeyCode, flag: CGEventFlags)] = []

        if flags.contains(.maskCommand) {
            modifiers.append((keyCode: 0x37, flag: .maskCommand))
        }
        if flags.contains(.maskShift) {
            modifiers.append((keyCode: 0x38, flag: .maskShift))
        }
        if flags.contains(.maskAlternate) {
            modifiers.append((keyCode: 0x3A, flag: .maskAlternate))
        }
        if flags.contains(.maskControl) {
            modifiers.append((keyCode: 0x3B, flag: .maskControl))
        }
        if flags.contains(.maskSecondaryFn) {
            modifiers.append((keyCode: 0x3F, flag: .maskSecondaryFn))
        }

        return modifiers
    }

    private static func postUnicodeCharacter(_ character: Character, targetProcessIdentifier: pid_t) throws {
        let string = String(character)
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            throw PeekabooError.operationError(message: "Failed to create background unicode keyboard events")
        }

        let chars = Array(string.utf16)
        chars.withUnsafeBufferPointer { buffer in
            keyDown.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: buffer.baseAddress!)
            keyUp.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: buffer.baseAddress!)
        }

        self.stampKeyboardRoutingFields(on: keyDown, targetProcessIdentifier: targetProcessIdentifier)
        self.stampKeyboardRoutingFields(on: keyUp, targetProcessIdentifier: targetProcessIdentifier)
        self.post(keyDown, to: targetProcessIdentifier)
        usleep(1000)
        self.post(keyUp, to: targetProcessIdentifier)
    }

    private static func keyboardStroke(for character: Character) -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        let string = String(character)
        guard string.count == 1 else { return nil }

        if let scalar = string.unicodeScalars.first,
           CharacterSet.lowercaseLetters.contains(scalar),
           let keyCode = self.keyCodes[string]
        {
            return (keyCode, [])
        }

        if let scalar = string.unicodeScalars.first,
           CharacterSet.uppercaseLetters.contains(scalar),
           let keyCode = self.keyCodes[string.lowercased()]
        {
            return (keyCode, .maskShift)
        }

        if let keyCode = self.keyCodes[string] {
            return (keyCode, [])
        }

        if let shifted = self.shiftedKeyCodes[character] {
            return (shifted, .maskShift)
        }

        return nil
    }

    static func stampKeyboardRoutingFields(on event: CGEvent, targetProcessIdentifier: pid_t) {
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(targetProcessIdentifier))
    }

    static func textByReplacingSelection(
        in currentText: String,
        selection: CFRange?,
        replacement: String) -> (text: String, cursorLocation: Int)
    {
        guard let selection,
              selection.location >= 0,
              selection.length >= 0
        else {
            return (currentText + replacement, currentText.utf16.count + replacement.utf16.count)
        }

        let utf16 = currentText.utf16
        guard let startUTF16 = utf16.index(
            utf16.startIndex,
            offsetBy: selection.location,
            limitedBy: utf16.endIndex),
            let endUTF16 = utf16.index(
                startUTF16,
                offsetBy: selection.length,
                limitedBy: utf16.endIndex),
            let start = String.Index(startUTF16, within: currentText),
            let end = String.Index(endUTF16, within: currentText)
        else {
            return (currentText + replacement, currentText.utf16.count + replacement.utf16.count)
        }

        let updated = currentText.replacingCharacters(in: start..<end, with: replacement)
        return (updated, selection.location + replacement.utf16.count)
    }

    static func cursorLocationMovingLeft(from selection: CFRange, in text: String) -> Int {
        if selection.length > 0 {
            return selection.location
        }
        guard selection.location > 0,
              let cursor = self.stringIndex(in: text, utf16Offset: selection.location)
        else {
            return max(0, selection.location - 1)
        }

        return text.index(before: cursor).utf16Offset(in: text)
    }

    static func cursorLocationMovingRight(from selection: CFRange, in text: String) -> Int {
        if selection.length > 0 {
            return selection.location + selection.length
        }
        let textLength = text.utf16.count
        guard selection.location < textLength,
              let cursor = self.stringIndex(in: text, utf16Offset: selection.location)
        else {
            return min(textLength, selection.location + 1)
        }

        return text.index(after: cursor).utf16Offset(in: text)
    }

    private static func clampedSelection(_ selection: CFRange?, textLength: Int) -> CFRange {
        guard let selection,
              selection.location >= 0,
              selection.length >= 0
        else {
            return CFRange(location: textLength, length: 0)
        }

        let location = min(selection.location, textLength)
        let length = min(selection.length, textLength - location)
        return CFRange(location: location, length: length)
    }

    private static func deletionRangeBeforeSelection(_ selection: CFRange, in text: String) -> CFRange? {
        if selection.length > 0 {
            return selection
        }
        guard selection.location > 0,
              let cursor = self.stringIndex(in: text, utf16Offset: selection.location)
        else {
            return nil
        }

        let previous = text.index(before: cursor)
        return CFRange(
            location: previous.utf16Offset(in: text),
            length: cursor.utf16Offset(in: text) - previous.utf16Offset(in: text))
    }

    private static func deletionRangeAfterSelection(_ selection: CFRange, in text: String) -> CFRange? {
        if selection.length > 0 {
            return selection
        }
        guard let cursor = self.stringIndex(in: text, utf16Offset: selection.location),
              cursor < text.endIndex
        else {
            return nil
        }

        let next = text.index(after: cursor)
        return CFRange(
            location: cursor.utf16Offset(in: text),
            length: next.utf16Offset(in: text) - cursor.utf16Offset(in: text))
    }

    private static func stringIndex(in text: String, utf16Offset: Int) -> String.Index? {
        let utf16 = text.utf16
        guard let utf16Index = utf16.index(
            utf16.startIndex,
            offsetBy: utf16Offset,
            limitedBy: utf16.endIndex)
        else {
            return nil
        }
        return String.Index(utf16Index, within: text)
    }

    private static func focusedEditableTextElement(targetProcessIdentifier: pid_t) throws -> AXUIElement? {
        let application = AXUIElementCreateApplication(targetProcessIdentifier)
        var focusedValue: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue)

        guard focusedError != .apiDisabled else {
            throw PeekabooError.permissionDeniedAccessibility
        }
        guard focusedError == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else {
            return nil
        }

        let element = unsafeDowncast(focusedValue, to: AXUIElement.self)
        guard !self.isSecureTextElement(element),
              self.isValueSettable(element)
        else {
            return nil
        }
        return element
    }

    private static func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable)
        return error == .success && settable.boolValue
    }

    private static func isSecureTextElement(_ element: AXUIElement) -> Bool {
        let role = self.stringAttribute(kAXRoleAttribute as CFString, from: element)
        let subrole = self.stringAttribute(kAXSubroleAttribute as CFString, from: element)
        return role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    private static func textValue(from element: AXUIElement) throws -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value)
        guard error != .apiDisabled else {
            throw PeekabooError.permissionDeniedAccessibility
        }
        guard error == .success else {
            return nil
        }
        return value as? String
    }

    private static func setText(_ text: String, on element: AXUIElement) throws -> Bool {
        let error = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            text as CFTypeRef)
        switch error {
        case .success:
            return true
        case .apiDisabled:
            throw PeekabooError.permissionDeniedAccessibility
        default:
            return false
        }
    }

    private static func selectedTextRange(from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value)
        guard error == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        var range = CFRange(location: 0, length: 0)
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    private static func setSelectedTextRange(_ range: CFRange, on element: AXUIElement) {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else {
            return
        }
        _ = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value)
    }

    private static func stringAttribute(_ attributeName: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attributeName, &value)
        guard error == .success else { return nil }
        return value as? String
    }

    static func resolveTargetWindowID(
        at point: CGPoint,
        targetProcessIdentifier: pid_t,
        exactWindowID: CGWindowID?,
        candidates: [MouseWindowRouteCandidate]) throws -> CGWindowID?
    {
        if let exactWindowID {
            guard let candidate = candidates.first(where: { $0.windowID == exactWindowID }) else {
                throw PeekabooError.snapshotStale("Target window \(exactWindowID) no longer exists")
            }
            guard candidate.processIdentifier == targetProcessIdentifier else {
                throw PeekabooError.snapshotStale(
                    "Target window \(exactWindowID) is now owned by another process")
            }
            guard candidate.layer == 0 else {
                throw PeekabooError.snapshotStale("Target window \(exactWindowID) is no longer interactive")
            }
            guard candidate.bounds.contains(point) else {
                throw PeekabooError.snapshotStale(
                    "Resolved click point is outside target window \(exactWindowID); capture a fresh snapshot")
            }
            return exactWindowID
        }

        return candidates.first {
            $0.processIdentifier == targetProcessIdentifier &&
                $0.layer == 0 &&
                $0.bounds.contains(point)
        }?.windowID
    }

    static func mouseWindowRouteCandidates(
        exactWindowID: CGWindowID?,
        copyWindowInfo: (CGWindowListOption, CGWindowID) -> [[String: Any]]? = { options, relativeToWindow in
            CGWindowListCopyWindowInfo(options, relativeToWindow) as? [[String: Any]]
        }) -> [MouseWindowRouteCandidate]
    {
        let options: CGWindowListOption
        let relativeToWindow: CGWindowID
        if let exactWindowID {
            // On-screen enumeration omits live windows on other Spaces; exact routes must query by ID.
            options = [.optionIncludingWindow, .excludeDesktopElements]
            relativeToWindow = exactWindowID
        } else {
            options = [.optionOnScreenOnly, .excludeDesktopElements]
            relativeToWindow = kCGNullWindowID
        }

        guard let windows = copyWindowInfo(options, relativeToWindow)
        else {
            return []
        }

        return windows.compactMap { window in
            guard let processIdentifier = self.pid(from: window[kCGWindowOwnerPID as String]),
                  let layer = self.intValue(from: window[kCGWindowLayer as String]),
                  let windowID = self.windowID(from: window[kCGWindowNumber as String]),
                  let boundsValue = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsValue as CFDictionary)
            else { return nil }

            return MouseWindowRouteCandidate(
                windowID: windowID,
                processIdentifier: processIdentifier,
                layer: layer,
                bounds: bounds)
        }
    }

    private static func windowID(from value: Any?) -> CGWindowID? {
        self.intValue(from: value).map(CGWindowID.init)
    }

    private static func pid(from value: Any?) -> pid_t? {
        self.intValue(from: value).map(pid_t.init)
    }

    private static func intValue(from value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let int = value as? Int {
            return int
        }
        if let int32 = value as? Int32 {
            return Int(int32)
        }
        if let uint32 = value as? UInt32 {
            return Int(uint32)
        }
        return nil
    }

    private static func isProcessAlive(_ processIdentifier: pid_t) -> Bool {
        errno = 0
        if kill(processIdentifier, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
        "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32, " ": 0x31,
    ]

    private static let shiftedKeyCodes: [Character: CGKeyCode] = [
        "!": 0x12, "@": 0x13, "#": 0x14, "$": 0x15, "%": 0x17, "^": 0x16, "&": 0x1A, "*": 0x1C,
        "(": 0x19, ")": 0x1D, "_": 0x1B, "+": 0x18, "{": 0x21, "}": 0x1E, "|": 0x2A, ":": 0x29,
        "\"": 0x27, "<": 0x2B, ">": 0x2F, "?": 0x2C, "~": 0x32,
    ]
}

extension BackgroundInputDriver {
    static let doubleClickUnsupportedMessage = """
    Background double-click is not supported: macOS delivers pid-targeted mouse events at the \
    window origin instead of the requested point. Re-run with --foreground to focus the app and \
    send a real double-click.
    """

    static let middleClickUnsupportedMessage = """
    Background middle-click is not supported: accessibility has no middle-button action and \
    pid-targeted mouse events cannot be positioned. Re-run with --foreground to send a real \
    middle-click.
    """

    static let unverifiedPressMessage = """
    The accessibility press did not complete, so Peekaboo cannot verify that the click was delivered. \
    Re-run with --foreground --input-strategy synthOnly to focus the app and send a real mouse click.
    """

    fileprivate static let nonPressableContainerRoles: Set<String> = [
        "AXApplication",
        "AXGroup",
        "AXLayoutArea",
        "AXRadioGroup",
        "AXScrollArea",
        "AXWebArea",
        "AXWindow",
    ]

    static func noActionableElementMessage(at point: CGPoint, targetProcessIdentifier: pid_t) -> String {
        """
        No pressable accessibility element was found at (\(Int(point.x)), \(Int(point.y))) in \
        PID \(targetProcessIdentifier). Background clicks press the accessibility element at the \
        target point, and nothing pressable was found there — the point may be empty, a \
        custom-drawn view, or an element that exposes no press action. Re-run with --foreground \
        --input-strategy synthOnly to focus the app and send a real mouse click at these coordinates.
        """
    }

    static func occludedWindowMessage(at point: CGPoint, targetWindowID: CGWindowID) -> String {
        """
        Point (\(Int(point.x)), \(Int(point.y))) is occluded for the pinned target window \
        \(targetWindowID): accessibility hit-testing resolved an element in a different window of \
        the same app. Background clicks press the frontmost element at the point and cannot reach \
        an overlapped window. Move the overlapping window aside, or re-run with --foreground to \
        raise and click the target window.
        """
    }
}

private enum SkyLightPerPidEventPost {
    private typealias PostToPidFn = @convention(c) (pid_t, CGEvent) -> Void

    private static let postToPid: PostToPidFn? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY)
        else {
            return nil
        }
        guard let symbol = dlsym(handle, "SLEventPostToPid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: PostToPidFn.self)
    }()

    @discardableResult
    static func post(_ event: CGEvent, to pid: pid_t) -> Bool {
        guard let postToPid else {
            return false
        }
        postToPid(pid, event)
        return true
    }
}
