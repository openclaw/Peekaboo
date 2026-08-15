import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct FocusedElementReceiptResolverTests {
    private let bounds = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test
    func `fresh exact observation attaches the sole explicit focused element`() throws {
        let element = self.element(id: "elem_1", identifier: "editor", focused: true)
        let context = self.context()

        let attached = FocusedElementReceiptResolver.attachingObservedFocus(
            to: context,
            elements: [element])
        let receipt = try #require(attached?.focusedElement)

        #expect(receipt.processIdentifier == 700)
        #expect(receipt.windowID == 42)
        #expect(receipt.role == "AXTextField")
        #expect(receipt.identifier == "editor")
        #expect(receipt.frame == element.bounds)
    }

    @Test
    func `cached tree never republishes mutable focus evidence`() {
        let result = FocusedElementReceiptResolver.clearingObservedFocus(from: self.context())

        #expect(result?.focusedElement == nil)
    }

    @Test
    func `zero multiple and outside focused candidates fail closed`() {
        let context = self.context()
        #expect(throws: FocusedElementReceiptError.noFocusedElement) {
            _ = try FocusedElementReceiptResolver.uniqueReceipt(
                elements: [self.element(id: "one", identifier: "one", focused: false)],
                context: context)
        }
        #expect(throws: FocusedElementReceiptError.multipleFocusedElements) {
            _ = try FocusedElementReceiptResolver.uniqueReceipt(
                elements: [
                    self.element(id: "one", identifier: "one", focused: true),
                    self.element(id: "two", identifier: "two", focused: true),
                ],
                context: context)
        }
        #expect(throws: FocusedElementReceiptError.elementOutsideWindow) {
            _ = try FocusedElementReceiptResolver.uniqueReceipt(
                elements: [self.element(
                    id: "outside",
                    identifier: "outside",
                    focused: true,
                    frame: CGRect(x: 1, y: 1, width: 20, height: 20))],
                context: context)
        }
    }

    @Test
    func `application menu focus is not admitted as exact window evidence`() {
        var element = self.element(id: "menu", identifier: "menu", focused: true)
        var attributes = element.attributes
        attributes[DetectedElementRootPolicy.sourceAttribute] = DetectedElementRootPolicy.applicationMenuBarSource
        element = DetectedElement(
            id: element.id,
            type: element.type,
            label: element.label,
            value: element.value,
            bounds: element.bounds,
            isEnabled: element.isEnabled,
            isSelected: element.isSelected,
            attributes: attributes)

        #expect(throws: FocusedElementReceiptError.noFocusedElement) {
            _ = try FocusedElementReceiptResolver.uniqueReceipt(elements: [element], context: self.context())
        }
    }

    @Test
    func `focus receipt codable additions preserve legacy payload compatibility`() throws {
        let focused = FocusedElementIdentity(
            processIdentifier: 700,
            windowID: 42,
            role: "AXTextField",
            identifier: "editor",
            frame: CGRect(x: 150, y: 180, width: 250, height: 30))
        let current = WindowContext(
            applicationProcessId: 700,
            windowID: 42,
            windowBounds: self.bounds,
            focusedElement: focused)
        let roundTrip = try JSONDecoder().decode(
            WindowContext.self,
            from: JSONEncoder().encode(current))
        #expect(roundTrip.focusedElement == focused)

        let legacyContext = try JSONDecoder().decode(
            WindowContext.self,
            from: Data(#"{"applicationProcessId":700,"windowID":42}"#.utf8))
        #expect(legacyContext.focusedElement == nil)

        let snapshot = UIAutomationSnapshot(
            applicationProcessId: 700,
            windowBounds: self.bounds,
            focusedElement: focused,
            windowID: 42)
        let snapshotRoundTrip = try JSONDecoder().decode(
            UIAutomationSnapshot.self,
            from: JSONEncoder().encode(snapshot))
        #expect(snapshotRoundTrip.focusedElement == focused)
    }

    @Test
    func `title fallback selects one same-frame sibling in either order`() {
        let frame = CGRect(x: 150, y: 180, width: 250, height: 30)
        for expectedIdentifier: String? in [nil, ""] {
            let expected = self.focusedIdentity(
                title: "Account name",
                identifier: expectedIdentifier,
                frame: frame)
            let wanted = self.focusedIdentity(title: "Account name", identifier: nil, frame: frame)
            let sibling = self.focusedIdentity(title: "Password", identifier: nil, frame: frame)

            for candidates in [[wanted, sibling], [sibling, wanted]] {
                let matches = candidates.filter {
                    FocusedElementReceiptResolver.matches($0, expected: expected)
                }
                #expect(matches == [wanted])
            }
        }
    }

    @Test
    func `title fallback rejects missing and empty observed titles`() {
        let expected = self.focusedIdentity(title: "Account name", identifier: nil)

        #expect(!FocusedElementReceiptResolver.matches(
            self.focusedIdentity(title: nil, identifier: nil),
            expected: expected))
        #expect(!FocusedElementReceiptResolver.matches(
            self.focusedIdentity(title: "", identifier: nil),
            expected: expected))
    }

    @Test
    func `nonempty identifier remains authoritative over title`() {
        let expected = self.focusedIdentity(title: "Old title", identifier: "account-name")

        #expect(FocusedElementReceiptResolver.matches(
            self.focusedIdentity(title: "New title", identifier: "account-name"),
            expected: expected))
        #expect(!FocusedElementReceiptResolver.matches(
            self.focusedIdentity(title: "Old title", identifier: nil),
            expected: expected))
    }

    private func context() -> WindowContext {
        WindowContext(
            applicationName: "Editor",
            applicationProcessId: 700,
            windowTitle: "Document",
            windowID: 42,
            windowBounds: self.bounds,
            windowMutationIdentity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: 700,
                ownerProcessStartIdentity: 99,
                capturedBounds: self.bounds))
    }

    private func focusedIdentity(
        title: String?,
        identifier: String?,
        frame: CGRect = CGRect(x: 150, y: 180, width: 250, height: 30)) -> FocusedElementIdentity
    {
        FocusedElementIdentity(
            processIdentifier: 700,
            windowID: 42,
            role: "AXTextField",
            title: title,
            identifier: identifier,
            frame: frame)
    }

    private func element(
        id: String,
        identifier: String,
        focused: Bool,
        frame: CGRect = CGRect(x: 150, y: 180, width: 250, height: 30)) -> DetectedElement
    {
        DetectedElement(
            id: id,
            type: .textField,
            label: "Editor",
            bounds: frame,
            isEnabled: true,
            attributes: [
                "role": "AXTextField",
                "identifier": identifier,
                "isFocused": String(focused),
            ])
    }
}
