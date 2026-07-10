import AppKit
import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation

enum ActionInputUnsupportedReason: String, Codable, Equatable {
    case actionUnsupported
    case attributeUnsupported
    case valueNotSettable
    case secureValueNotAllowed
    case menuShortcutUnavailable
    case missingElement
}

enum ActionInputError: Error, Equatable {
    case unsupported(ActionInputUnsupportedReason)
    case staleElement
    case permissionDenied
    case targetUnavailable
    case failed(String)
}

extension ActionInputUnsupportedReason: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .actionUnsupported:
            "Accessibility action is not supported"
        case .attributeUnsupported:
            "Accessibility attribute is not supported"
        case .valueNotSettable:
            "Accessibility value is not settable"
        case .secureValueNotAllowed:
            "Direct value setting is not allowed for secure text fields"
        case .menuShortcutUnavailable:
            "No menu item matches that shortcut"
        case .missingElement:
            "No accessibility element is available for action invocation"
        }
    }
}

extension ActionInputError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .unsupported(reason):
            reason.errorDescription
        case .staleElement:
            "Accessibility element is stale; run see again"
        case .permissionDenied:
            "Accessibility permission is denied"
        case .targetUnavailable:
            "Accessibility target is unavailable"
        case let .failed(reason):
            reason
        }
    }
}

struct ActionInputResult: Equatable {
    var actionName: String?
    var anchorPoint: CGPoint?
    var elementRole: String?

    init(actionName: String? = nil, anchorPoint: CGPoint? = nil, elementRole: String? = nil) {
        self.actionName = actionName
        self.anchorPoint = anchorPoint
        self.elementRole = elementRole
    }
}

@MainActor
protocol ActionInputDriving: Sendable {
    func tryClick(element: AutomationElement) throws -> ActionInputResult
    func tryRightClick(element: any AutomationElementRepresenting) async throws -> ActionInputResult
    func tryScroll(
        element: AutomationElement,
        direction: PeekabooFoundation.ScrollDirection,
        pages: Int) throws -> ActionInputResult
    func trySetText(element: AutomationElement, text: String, replace: Bool) throws -> ActionInputResult
    func tryHotkey(application: NSRunningApplication, keys: [String]) throws -> ActionInputResult
    func trySetValue(element: AutomationElement, value: UIElementValue) throws -> ActionInputResult
    func tryPerformAction(element: AutomationElement, actionName: String) throws -> ActionInputResult
}

/// Accessibility action implementation for action-first UI input.
@MainActor
struct ActionInputDriver: ActionInputDriving {
    func tryClick(element: AutomationElement) throws -> ActionInputResult {
        do {
            return try self.performAction(AXActionNames.kAXPressAction, on: element)
        } catch let error as ActionInputError
            where error == .unsupported(.actionUnsupported) &&
            Self.canFocusForClick(
                role: element.role,
                subrole: element.subrole,
                isValueSettable: element.isValueSettable,
                isFocusedSettable: element.isFocusedSettable)
        {
            return try self.focusForClick(element)
        }
    }

    func tryRightClick(element: any AutomationElementRepresenting) async throws -> ActionInputResult {
        do {
            return try await self.performShowMenuAction(on: element)
        } catch ActionInputError.targetUnavailable {
            throw ActionInputError.unsupported(.actionUnsupported)
        }
    }

    /// Issues `AXShowMenu` without waiting on the menu's tracking runloop.
    ///
    /// A successful `AXShowMenu` opens an NSMenu whose tracking loop is a nested runloop on the
    /// target app's main thread, so `AXUIElementPerformAction` does not return until the menu is
    /// dismissed. Awaiting it deadlocks the caller (and blocks a bridge host's main actor) until
    /// the client times out even though the menu is visibly open. The action is therefore issued
    /// from a detached thread; if it is still running after a short grace period, the menu is
    /// considered open and the right-click reports success.
    private func performShowMenuAction(on element: any AutomationElementRepresenting) async throws
        -> ActionInputResult
    {
        // Attribute reads happen before the action while the target app is still responsive.
        let result = ActionInputResult(
            actionName: AXActionNames.kAXShowMenuAction,
            anchorPoint: element.anchorPoint,
            elementRole: element.role)

        guard let axElement = element.underlyingAXElement else {
            // In-memory test elements have no AX identity and cannot block; act synchronously.
            _ = try self.performAction(AXActionNames.kAXShowMenuAction, on: element)
            return result
        }

        let outcome = await DetachedAXActionRunner.perform(
            action: AXActionNames.kAXShowMenuAction,
            on: axElement,
            gracePeriod: DetachedAXActionRunner.showMenuGracePeriod)
        switch outcome {
        case .completed(.success), .stillRunning:
            return result
        case let .completed(axError):
            throw Self.classify(axError)
        }
    }

    func tryScroll(
        element: AutomationElement,
        direction: PeekabooFoundation.ScrollDirection,
        pages: Int) throws -> ActionInputResult
    {
        try self.performScrollActions(element: element, direction: direction, pages: pages)
    }

    func trySetText(element: AutomationElement, text: String, replace: Bool) throws -> ActionInputResult {
        guard replace else {
            throw ActionInputError.unsupported(.attributeUnsupported)
        }
        return try self.trySetValue(element: element, value: .string(text))
    }

    func tryHotkey(application: NSRunningApplication, keys: [String]) throws -> ActionInputResult {
        let chord = try MenuHotkeyChord(keys: keys)
        let appElement = AXApp(application).element
        guard let menuBar = appElement.menuBarWithTimeout(timeout: 1.0).map(AutomationElement.init) else {
            throw ActionInputError.unsupported(.missingElement)
        }

        guard let menuItem = self.findMenuItem(matching: chord, in: menuBar) else {
            throw ActionInputError.unsupported(.menuShortcutUnavailable)
        }

        return try self.performAction(AXActionNames.kAXPressAction, on: menuItem)
    }

    func trySetValue(element: AutomationElement, value: UIElementValue) throws -> ActionInputResult {
        try self.setValue(value, on: element)
    }

    func tryPerformAction(element: AutomationElement, actionName: String) throws -> ActionInputResult {
        try self.performAction(actionName, on: element)
    }

    nonisolated static func classify(_ error: any Error) -> ActionInputError {
        if let actionError = error as? ActionInputError {
            return actionError
        }

        if let systemError = error as? AccessibilitySystemError {
            return self.classify(systemError.axError)
        }

        return .failed(error.localizedDescription)
    }

    nonisolated static func classify(_ error: AXError) -> ActionInputError {
        switch error {
        case .actionUnsupported:
            .unsupported(.actionUnsupported)
        case .attributeUnsupported, .parameterizedAttributeUnsupported:
            .unsupported(.attributeUnsupported)
        case .invalidUIElement, .invalidUIElementObserver:
            .staleElement
        case .apiDisabled:
            .permissionDenied
        case .cannotComplete, .failure:
            .targetUnavailable
        default:
            .failed(error.localizedDescription)
        }
    }

    nonisolated static func setValueRejectionReason(
        role: String?,
        subrole: String?,
        isValueSettable: Bool) -> ActionInputUnsupportedReason?
    {
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            return .secureValueNotAllowed
        }
        if !isValueSettable {
            return .valueNotSettable
        }
        return nil
    }

    nonisolated static func shouldContinueTryingScrollAction(after error: ActionInputError) -> Bool {
        error.isUnsupported || error == .targetUnavailable
    }

    nonisolated static func canFocusForClick(
        role: String?,
        subrole: String?,
        isValueSettable: Bool,
        isFocusedSettable: Bool) -> Bool
    {
        guard isFocusedSettable else { return false }
        switch role {
        case "AXTextField", "AXTextArea", "AXComboBox":
            return true
        default:
            return subrole == "AXSearchField" || isValueSettable
        }
    }

    nonisolated static func scrollFallbackError(from error: ActionInputError?) -> ActionInputError {
        if error == .targetUnavailable {
            return .unsupported(.actionUnsupported)
        }
        return error ?? .unsupported(.actionUnsupported)
    }

    private func performAction(_ actionName: String, on element: any AutomationElementRepresenting)
        throws -> ActionInputResult
    {
        do {
            try element.performAutomationAction(actionName)
            return ActionInputResult(
                actionName: actionName,
                anchorPoint: element.anchorPoint,
                elementRole: element.role)
        } catch {
            throw Self.classify(error)
        }
    }

    private func focusForClick(_ element: any AutomationElementRepresenting) throws -> ActionInputResult {
        do {
            try element.setAutomationFocused(true)
            return ActionInputResult(
                actionName: AXAttributeNames.kAXFocusedAttribute,
                anchorPoint: element.anchorPoint,
                elementRole: element.role)
        } catch {
            throw Self.classify(error)
        }
    }

    private func setValue(_ value: UIElementValue, on element: any AutomationElementRepresenting)
        throws -> ActionInputResult
    {
        if let rejectionReason = Self.setValueRejectionReason(
            role: element.role,
            subrole: element.subrole,
            isValueSettable: element.isValueSettable)
        {
            throw ActionInputError.unsupported(rejectionReason)
        }

        do {
            try element.setAutomationValue(value)
            return ActionInputResult(
                actionName: AXActionNames.kAXSetValueAction,
                anchorPoint: element.anchorPoint,
                elementRole: element.role)
        } catch {
            throw Self.classify(error)
        }
    }

    private func scrollActionNames(for direction: PeekabooFoundation.ScrollDirection) -> [String] {
        switch direction {
        case .up:
            ["AXScrollUpByPage", "AXPageUp"]
        case .down:
            ["AXScrollDownByPage", "AXPageDown"]
        case .left:
            ["AXScrollLeftByPage", "AXPageLeft"]
        case .right:
            ["AXScrollRightByPage", "AXPageRight"]
        }
    }

    private func performScrollActions(
        element: any AutomationElementRepresenting,
        direction: PeekabooFoundation.ScrollDirection,
        pages: Int) throws -> ActionInputResult
    {
        let actions = self.scrollActionNames(for: direction)
        var lastError: ActionInputError?
        var performedActionName: String?

        for _ in 0..<max(1, pages) {
            var performed = false
            for action in actions {
                do {
                    _ = try self.performAction(action, on: element)
                    performedActionName = action
                    performed = true
                    break
                } catch let error as ActionInputError {
                    lastError = error
                    if !Self.shouldContinueTryingScrollAction(after: error) {
                        throw error
                    }
                }
            }

            if !performed {
                throw Self.scrollFallbackError(from: lastError)
            }
        }

        return ActionInputResult(
            actionName: performedActionName,
            anchorPoint: element.anchorPoint,
            elementRole: element.role)
    }

    private func findMenuItem(
        matching chord: MenuHotkeyChord,
        in menuBar: any AutomationElementRepresenting) -> (any AutomationElementRepresenting)?
    {
        var remainingBudget = 600

        for menuBarItem in menuBar.automationChildren {
            guard remainingBudget > 0 else { return nil }
            remainingBudget -= 1

            guard let menu = menuBarItem.automationChildren.first(where: { $0.role == AXRoleNames.kAXMenuRole }) else {
                continue
            }

            if let match = self.findMenuItem(
                matching: chord,
                inMenuChildren: menu.automationChildren,
                budget: &remainingBudget)
            {
                return match
            }
        }

        return nil
    }

    private func findMenuItem(
        matching chord: MenuHotkeyChord,
        inMenuChildren children: [any AutomationElementRepresenting],
        budget: inout Int) -> (any AutomationElementRepresenting)?
    {
        for child in children {
            guard budget > 0 else { return nil }
            budget -= 1

            if self.menuItem(child, matches: chord) {
                return child
            }

            if let submenu = child.automationChildren.first(where: { $0.role == AXRoleNames.kAXMenuRole }),
               let match = self.findMenuItem(
                   matching: chord,
                   inMenuChildren: submenu.automationChildren,
                   budget: &budget)
            {
                return match
            }
        }

        return nil
    }

    private func menuItem(_ element: any AutomationElementRepresenting, matches chord: MenuHotkeyChord) -> Bool {
        guard element.role == AXRoleNames.kAXMenuItemRole else { return false }
        guard element.isEnabled else { return false }

        guard let commandCharacter = element.stringAttribute("AXMenuItemCmdChar"),
              !commandCharacter.isEmpty
        else {
            return false
        }

        let modifiers = element.intAttribute("AXMenuItemCmdModifiers") ?? 0
        return MenuHotkeyChord.normalizedCommandCharacter(commandCharacter) == chord.key &&
            MenuHotkeyChord.modifiers(fromMenuItemModifiers: modifiers) == chord.modifiers
    }
}

extension ActionInputError {
    fileprivate var isUnsupported: Bool {
        if case .unsupported = self {
            return true
        }
        return false
    }
}

private struct MenuHotkeyChord: Equatable {
    let key: String
    let modifiers: Set<String>

    init(keys: [String]) throws {
        var primaryKey: String?
        var modifiers: Set<String> = []

        for key in keys.map(Self.normalizedKey(_:)) where !key.isEmpty {
            if let modifier = Self.modifierName(for: key) {
                modifiers.insert(modifier)
                continue
            }

            guard let commandCharacter = Self.commandCharacter(for: key) else {
                throw ActionInputError.unsupported(.menuShortcutUnavailable)
            }

            if primaryKey != nil {
                throw ActionInputError.unsupported(.menuShortcutUnavailable)
            }
            primaryKey = commandCharacter
        }

        guard let primaryKey else {
            throw ActionInputError.unsupported(.menuShortcutUnavailable)
        }

        self.key = primaryKey
        self.modifiers = modifiers
    }

    static func normalizedCommandCharacter(_ raw: String) -> String {
        self.commandCharacter(for: raw) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func modifiers(fromMenuItemModifiers modifiers: Int) -> Set<String> {
        var result: Set<String> = []
        if modifiers & (1 << 3) == 0 {
            result.insert("cmd")
        }
        if modifiers & (1 << 0) != 0 {
            result.insert("shift")
        }
        if modifiers & (1 << 1) != 0 {
            result.insert("alt")
        }
        if modifiers & (1 << 2) != 0 {
            result.insert("ctrl")
        }
        return result
    }

    private static func normalizedKey(_ raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.aliases[key] ?? key
    }

    private static func modifierName(for key: String) -> String? {
        switch key {
        case "cmd", "shift", "alt", "ctrl":
            key
        default:
            nil
        }
    }

    private static func commandCharacter(for key: String) -> String? {
        let key = self.normalizedKey(key)
        if key.count == 1 {
            return key
        }
        return Self.namedCommandCharacters[key]
    }

    private static let aliases: [String: String] = [
        "command": "cmd",
        "control": "ctrl",
        "option": "alt",
        "opt": "alt",
        "spacebar": "space",
        "left_bracket": "leftbracket",
        "[": "leftbracket",
        "right_bracket": "rightbracket",
        "]": "rightbracket",
        "=": "equal",
        "-": "minus",
        "'": "quote",
        ";": "semicolon",
        "\\": "backslash",
        ",": "comma",
        "/": "slash",
        ".": "period",
        "`": "grave",
    ]

    private static let namedCommandCharacters: [String: String] = [
        "space": " ",
        "leftbracket": "[",
        "rightbracket": "]",
        "equal": "=",
        "minus": "-",
        "quote": "'",
        "semicolon": ";",
        "backslash": "\\",
        "comma": ",",
        "slash": "/",
        "period": ".",
        "grave": "`",
    ]
}

#if DEBUG
extension ActionInputDriver {
    func tryClickForTesting(element: any AutomationElementRepresenting) throws -> ActionInputResult {
        do {
            return try self.performAction(AXActionNames.kAXPressAction, on: element)
        } catch let error as ActionInputError
            where error == .unsupported(.actionUnsupported) &&
            Self.canFocusForClick(
                role: element.role,
                subrole: element.subrole,
                isValueSettable: element.isValueSettable,
                isFocusedSettable: element.isFocusedSettable)
        {
            return try self.focusForClick(element)
        }
    }

    func trySetValueForTesting(
        element: any AutomationElementRepresenting,
        value: UIElementValue) throws -> ActionInputResult
    {
        try self.setValue(value, on: element)
    }

    func tryScrollForTesting(
        element: any AutomationElementRepresenting,
        direction: PeekabooFoundation.ScrollDirection,
        pages: Int) throws -> ActionInputResult
    {
        try self.performScrollActions(element: element, direction: direction, pages: pages)
    }

    func tryPerformActionForTesting(
        element: any AutomationElementRepresenting,
        actionName: String) throws -> ActionInputResult
    {
        try self.performAction(actionName, on: element)
    }

    func tryHotkeyForTesting(
        keys: [String],
        menuBar: any AutomationElementRepresenting) throws -> ActionInputResult
    {
        let chord = try MenuHotkeyChord(keys: keys)
        guard let menuItem = self.findMenuItem(matching: chord, in: menuBar) else {
            throw ActionInputError.unsupported(.menuShortcutUnavailable)
        }
        return try self.performAction(AXActionNames.kAXPressAction, on: menuItem)
    }

    nonisolated static func menuHotkeyChordForTesting(_ keys: [String]) throws
        -> (key: String, modifiers: Set<String>)
    {
        let chord = try MenuHotkeyChord(keys: keys)
        return (chord.key, chord.modifiers)
    }

    nonisolated static func menuHotkeyModifiersForTesting(_ modifiers: Int) -> Set<String> {
        MenuHotkeyChord.modifiers(fromMenuItemModifiers: modifiers)
    }

    nonisolated static func setValueRejectionReasonForTesting(
        role: String?,
        subrole: String? = nil,
        isValueSettable: Bool) -> ActionInputUnsupportedReason?
    {
        self.setValueRejectionReason(role: role, subrole: subrole, isValueSettable: isValueSettable)
    }

    nonisolated static func canFocusForClickForTesting(
        role: String?,
        subrole: String? = nil,
        isValueSettable: Bool,
        isFocusedSettable: Bool) -> Bool
    {
        self.canFocusForClick(
            role: role,
            subrole: subrole,
            isValueSettable: isValueSettable,
            isFocusedSettable: isFocusedSettable)
    }

    nonisolated static func shouldContinueTryingScrollActionForTesting(after error: ActionInputError) -> Bool {
        self.shouldContinueTryingScrollAction(after: error)
    }

    nonisolated static func scrollFallbackErrorForTesting(from error: ActionInputError?) -> ActionInputError {
        self.scrollFallbackError(from: error)
    }
}
#endif
