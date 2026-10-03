import ApplicationServices
import AXorcist
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct MenuValueTitleTests {
    @Test
    func `menu extra matching includes a normalized string value`() {
        let element = self.element(value: .string("Value Only"))

        #expect(MenuService().menuItemMatchesTitle(element, normalizedTarget: "value only"))
    }

    @Test
    func `menu extra matching retains title and description alternatives`() {
        let element = self.element(title: "Title", description: "Description", value: .string("Value"))
        let service = MenuService()

        for candidate in ["title", "description", "value"] {
            #expect(service.menuItemMatchesTitle(element, normalizedTarget: candidate))
        }
    }

    @Test(arguments: [AttributeValue.bool(true), .int(7), .double(1.5), .null])
    func `menu values do not coerce nontext metadata into labels`(value: AttributeValue) {
        let element = self.element(value: value)
        let service = MenuService()

        for candidate in ["true", "7", "1.5", "null"] {
            #expect(!service.menuItemMatchesTitle(element, normalizedTarget: candidate))
        }
    }

    private func element(
        title: String = "",
        description: String = "",
        value: AttributeValue) -> Element
    {
        // Prefetched metadata cannot target a live app through this invalid PID.
        Element(
            AXUIElementCreateApplication(-1),
            attributes: [
                "AXTitle": .string(title),
                "AXDescription": .string(description),
                "AXValue": value,
            ],
            children: [],
            actions: [])
    }
}
