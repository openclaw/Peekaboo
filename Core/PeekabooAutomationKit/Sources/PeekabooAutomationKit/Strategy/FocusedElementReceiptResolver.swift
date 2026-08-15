import CoreGraphics
import Foundation
import PeekabooFoundation

/// Builds exact focused-element receipts only from explicit AXFocused observation evidence.
public enum FocusedElementReceiptResolver {
    public static func uniqueReceipt(
        elements: [DetectedElement],
        context: WindowContext) throws -> FocusedElementIdentity
    {
        let focused = elements.filter {
            $0.isFocused == true &&
                $0.attributes[DetectedElementRootPolicy.sourceAttribute]?
                .caseInsensitiveCompare(DetectedElementRootPolicy.applicationMenuBarSource) != .orderedSame
        }
        guard !focused.isEmpty else { throw FocusedElementReceiptError.noFocusedElement }
        guard focused.count == 1, let element = focused.first else {
            throw FocusedElementReceiptError.multipleFocusedElements
        }
        return try self.receipt(element: element, context: context)
    }

    public static func receipt(
        element: DetectedElement,
        context: WindowContext) throws -> FocusedElementIdentity
    {
        guard let processIdentifier = context.applicationProcessId, processIdentifier > 0 else {
            throw FocusedElementReceiptError.missingProcessIdentifier
        }
        guard let windowID = context.windowID, windowID > 0 else {
            throw FocusedElementReceiptError.missingWindowIdentifier
        }
        guard let windowBounds = context.windowBounds, !windowBounds.isEmpty else {
            throw FocusedElementReceiptError.missingWindowBounds
        }
        guard !element.bounds.isEmpty else {
            throw FocusedElementReceiptError.missingElementFrame
        }
        guard windowBounds.contains(CGPoint(x: element.bounds.midX, y: element.bounds.midY)) else {
            throw FocusedElementReceiptError.elementOutsideWindow
        }
        return FocusedElementIdentity(
            processIdentifier: processIdentifier,
            windowID: windowID,
            role: element.attributes["role"] ?? Self.role(for: element.type),
            title: element.attributes["title"],
            identifier: element.attributes["identifier"],
            frame: element.bounds)
    }

    public static func validate(
        _ actual: FocusedElementIdentity,
        matches expected: FocusedElementIdentity) throws
    {
        guard actual.processIdentifier == expected.processIdentifier else {
            throw FocusedElementReceiptError.processMismatch
        }
        guard actual.windowID == expected.windowID else {
            throw FocusedElementReceiptError.windowMismatch
        }
        guard actual.role == expected.role else {
            throw FocusedElementReceiptError.roleMismatch
        }
        guard actual.frame == expected.frame else {
            throw FocusedElementReceiptError.frameMismatch
        }
        if let identifier = expected.identifier, !identifier.isEmpty, actual.identifier != identifier {
            throw FocusedElementReceiptError.identifierMismatch
        }
        if expected.identifier?.isEmpty != false,
           let title = expected.title,
           !title.isEmpty,
           actual.title != title
        {
            throw FocusedElementReceiptError.titleMismatch
        }
    }

    static func matches(
        _ actual: FocusedElementIdentity,
        expected: FocusedElementIdentity) -> Bool
    {
        do {
            try self.validate(actual, matches: expected)
            return true
        } catch {
            return false
        }
    }

    public static func attachingObservedFocus(
        to context: WindowContext?,
        elements: [DetectedElement]) -> WindowContext?
    {
        guard let context else { return nil }
        let focusedElement = try? self.uniqueReceipt(elements: elements, context: context)
        return WindowContext(
            applicationName: context.applicationName,
            applicationBundleId: context.applicationBundleId,
            applicationProcessId: context.applicationProcessId,
            windowTitle: context.windowTitle,
            windowID: context.windowID,
            windowBounds: context.windowBounds,
            windowMutationIdentity: context.windowMutationIdentity,
            focusedElement: focusedElement,
            shouldFocusWebContent: context.shouldFocusWebContent,
            includeMenuBarElements: context.includeMenuBarElements,
            traversalBudget: context.traversalBudget,
            requiresFreshAccessibilityTree: context.requiresFreshAccessibilityTree ?? false,
            accessibilityTimeoutSeconds: context.accessibilityTimeoutSeconds)
    }

    public static func clearingObservedFocus(from context: WindowContext?) -> WindowContext? {
        guard let context else { return nil }
        return WindowContext(
            applicationName: context.applicationName,
            applicationBundleId: context.applicationBundleId,
            applicationProcessId: context.applicationProcessId,
            windowTitle: context.windowTitle,
            windowID: context.windowID,
            windowBounds: context.windowBounds,
            windowMutationIdentity: context.windowMutationIdentity,
            focusedElement: nil,
            shouldFocusWebContent: context.shouldFocusWebContent,
            includeMenuBarElements: context.includeMenuBarElements,
            traversalBudget: context.traversalBudget,
            requiresFreshAccessibilityTree: context.requiresFreshAccessibilityTree ?? false,
            accessibilityTimeoutSeconds: context.accessibilityTimeoutSeconds)
    }

    private static func role(for type: ElementType) -> String {
        switch type {
        case .button: "AXButton"
        case .textField: "AXTextField"
        case .link: "AXLink"
        case .image: "AXImage"
        case .group: "AXGroup"
        case .slider: "AXSlider"
        case .checkbox: "AXCheckBox"
        case .menu: "AXMenu"
        case .staticText: "AXStaticText"
        case .radioButton: "AXRadioButton"
        case .menuItem: "AXMenuItem"
        case .window: "AXWindow"
        case .dialog: "AXDialog"
        case .other: "AXUnknown"
        }
    }
}
