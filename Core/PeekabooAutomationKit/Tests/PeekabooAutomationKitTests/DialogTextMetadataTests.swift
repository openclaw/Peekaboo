import ApplicationServices
import AXorcist
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct DialogTextMetadataTests {
    @Test
    func `nested alert message and informative text reach dialog metadata`() {
        let message = Self.element(1, role: "AXStaticText", value: "Peekaboo Playground Alert")
        let information = Self.element(2, role: "AXStaticText", value: "Use dialog click to press buttons.")
        let field = Self.element(3, role: "AXTextField", title: "Name", value: "Ada")
        let area = Self.element(4, role: "AXTextArea", title: "Notes", value: "Draft", enabled: false)
        let cancel = Self.element(5, role: "AXButton", title: "Cancel")
        let ok = Self.element(6, role: "AXButton", title: "OK", isDefault: true)
        let content = Self.element(7, children: [
            message,
            Self.element(8, children: [information, field, area]),
        ])
        let dialog = Self.element(9, role: "AXSheet", children: [content, cancel, ok])
        let service = DialogService()

        let result = service.dialogElements(for: dialog)

        #expect(result.dialogInfo.role == "AXSheet")
        #expect(result.dialogInfo.title.isEmpty)
        #expect(result.staticTexts == ["Peekaboo Playground Alert", "Use dialog click to press buttons."])
        #expect(result.buttons.map(\.title) == ["Cancel", "OK"])
        #expect(result.buttons.map(\.isDefault) == [false, true])
        #expect(result.buttons.map(\.isEnabled) == [true, true])
        #expect(result.textFields.map(\.title) == ["Name", "Notes"])
        #expect(result.textFields.map(\.value) == ["Ada", "Draft"])
        #expect(result.textFields.map(\.placeholder) == ["Name placeholder", "Notes placeholder"])
        #expect(result.textFields.map(\.index) == [0, 1])
        #expect(result.textFields.map(\.isEnabled) == [true, false])
        #expect(service.collectButtons(from: dialog) == [cancel, ok])
        #expect(service.collectTextFields(from: dialog) == [field, area])
        #expect(field.value() as? String == "Ada")
        #expect(area.value() as? String == "Draft")
    }

    @Test
    func `static text prefers content then falls back to nonblank AX names`() {
        let value = Self.element(
            1, role: "AXStaticText", title: "Title", value: "  Content\n", label: "Label", description: "Description")
        let title = Self.element(
            2, role: "AXStaticText", title: "Title", value: " \n", label: "Label", description: "Description")
        let label = Self.element(3, role: "AXStaticText", label: "Label", description: "Description")
        let description = Self.element(4, role: "AXStaticText", description: "Description")
        let empty = Self.element(5, role: "AXStaticText", value: " \n")
        let dialog = Self.element(6, role: "AXSheet", children: [value, title, label, description, empty])

        #expect(DialogService().dialogStaticTexts(from: dialog) == [
            "  Content\n", "Title", "Label", "Description",
        ])
    }

    @Test
    func `missing and nonstring values use text metadata without stringifying other values`() {
        var missing = Self.element(1, role: "AXStaticText", title: "Message")
        missing.attributes?.removeValue(forKey: "AXValue")
        var numeric = Self.element(2, role: "AXStaticText", description: "Information")
        numeric.attributes?["AXValue"] = .int(42)
        var opaque = Self.element(3, role: "AXStaticText")
        opaque.attributes?["AXValue"] = .array([.string("Not text content")])
        let dialog = Self.element(4, role: "AXSheet", children: [missing, numeric, opaque])

        #expect(DialogService().dialogStaticTexts(from: dialog) == ["Message", "Information"])
    }

    @Test
    func `shared AX identities are emitted once while equal text in distinct elements is retained`() {
        let first = Self.element(1, role: "AXStaticText", value: "Repeated")
        let second = Self.element(2, role: "AXStaticText", value: "Repeated")
        var dialog = Self.element(3, role: "AXSheet")
        let group = Self.element(4, children: [first, dialog, second])
        dialog.prefetchedChildren = [group, first]

        #expect(DialogService().dialogStaticTexts(from: dialog) == ["Repeated", "Repeated"])
    }

    @Test
    func `text extraction stays inside the selected dialog subtree`() {
        let outside = Self.element(1, role: "AXStaticText", value: "Other window text")
        let otherWindow = Self.element(2, role: "AXWindow", children: [outside])
        let application = Self.element(3, role: "AXApplication", children: [otherWindow])
        let message = Self.element(4, role: "AXStaticText", value: "Selected message")
        let dialog = Self.element(5, role: "AXWindow", children: [
            Self.element(6, children: [message, otherWindow, application]),
        ])
        let parent = Self.element(7, role: "AXWindow", children: [outside, dialog])

        #expect(parent.children() == [outside, dialog])
        #expect(DialogService().dialogStaticTexts(from: dialog) == ["Selected message"])
    }

    private static func element(
        _ identity: Int32,
        role: String = "AXGroup",
        title: String = "",
        value: String = "",
        label: String = "",
        description: String = "",
        enabled: Bool = true,
        isDefault: Bool = false,
        children: [Element] = []) -> Element
    {
        // Supported prefetched AX metadata exercises the production readers. Invalid PIDs cannot target a live app.
        Element(
            AXUIElementCreateApplication(-identity),
            attributes: [
                "AXRole": .string(role),
                "AXSubrole": .string(""),
                "AXTitle": .string(title),
                "AXValue": .string(value),
                "AXLabel": .string(label),
                "AXDescription": .string(description),
                "AXIdentifier": .string("fixture-\(identity)"),
                "AXRoleDescription": .string(role == "AXStaticText" ? "static text" : ""),
                "AXModal": .bool(role == "AXSheet"),
                "AXEnabled": .bool(enabled),
                "AXDefault": .bool(isDefault),
                "AXPlaceholderValue": .string("\(title) placeholder"),
            ],
            children: children,
            actions: [])
    }
}
