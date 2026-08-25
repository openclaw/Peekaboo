import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct ExactWindowSelectorResolverTests {
    @Test
    func `explicit resolution preserves receiptless compatibility selection`() throws {
        let receiptless = AutomationTestFixtures.window(includesMutationIdentity: false)

        let selected = try ExactWindowSelectorResolver.select(
            from: [receiptless],
            selection: .id(receiptless.windowID),
            operation: "Capture window selection",
            vocabulary: .mcp)

        #expect(selected == receiptless)
    }

    @Test
    func `automatic resolution uses the canonical observation ranking`() throws {
        let secondary = AutomationTestFixtures.window(
            windowID: 202,
            title: "Secondary",
            isMainWindow: false,
            isKeyWindow: false,
            index: 1)
        let primary = AutomationTestFixtures.window(
            windowID: 201,
            title: "Primary",
            isMainWindow: true,
            isKeyWindow: true,
            index: 0)

        let selected = try ExactWindowSelectorResolver.select(
            from: [secondary, primary],
            selection: .automatic,
            operation: "Capture window selection",
            vocabulary: .mcp)

        #expect(selected == primary)
    }

    @Test
    func `explicit resolution delegates canonical rows and selector semantics`() throws {
        let selected = AutomationTestFixtures.window(windowID: 201, title: "Project Notes", index: 4)
        let unrelated = AutomationTestFixtures.window(windowID: 202, title: "Other", index: 5)
        let conflicting = AutomationTestFixtures.window(windowID: 202, title: "Conflict", index: 6)

        for inventory in [
            [selected, selected, unrelated, conflicting],
            [conflicting, unrelated, selected, selected],
        ] {
            for selection: ExactWindowSelectorResolver.Selection in [
                .id(selected.windowID),
                .title("Notes"),
                .index(selected.index),
            ] {
                #expect(try ExactWindowSelectorResolver.select(
                    from: inventory,
                    selection: selection,
                    operation: "Capture window selection",
                    vocabulary: .mcp) == selected)
            }
        }
    }

    @Test
    func `command line vocabulary preserves title ambiguity wording`() {
        let first = AutomationTestFixtures.window(windowID: 101, title: "Draft One", index: 0)
        let second = AutomationTestFixtures.window(windowID: 102, title: "Draft Two", index: 1)

        let error = #expect(throws: ExactWindowSelectorResolutionError.self) {
            _ = try ExactWindowSelectorResolver.select(
                from: [second, first],
                selection: .title("Draft"),
                operation: "Capture selector test",
                vocabulary: .commandLine)
        }
        #expect(error?.message ==
            "Capture selector test window title 'Draft' is ambiguous " +
            "(id=101 index=0 'Draft One'; id=102 index=1 'Draft Two'). " +
            "Select one --window-id or --window-index explicitly.")
    }

    @Test
    func `MCP vocabulary preserves title ambiguity wording`() {
        let first = AutomationTestFixtures.window(windowID: 41, title: "Project Notes", index: 0)
        let second = AutomationTestFixtures.window(windowID: 42, title: "Project Plan", index: 1)

        let error = #expect(throws: ExactWindowSelectorResolutionError.self) {
            _ = try ExactWindowSelectorResolver.select(
                from: [second, first],
                selection: .title("Project"),
                operation: "Capture window selection",
                vocabulary: .mcp)
        }
        #expect(error?.message ==
            "Capture window selection window title 'Project' is ambiguous " +
            "(id=41 index=0 'Project Notes'; id=42 index=1 'Project Plan'). " +
            "Select one window_id or index explicitly.")
    }

    @Test
    func `surface vocabulary preserves missing selector wording`() {
        let window = AutomationTestFixtures.window(windowID: 201, title: "Available", index: 4)

        let cliID = #expect(throws: ExactWindowSelectorResolutionError.self) {
            _ = try ExactWindowSelectorResolver.select(
                from: [window],
                selection: .id(999),
                operation: "Window test",
                vocabulary: .commandLine)
        }
        #expect(cliID?.message ==
            "Window test --window-id 999 does not identify a window. " +
            "Refresh the window inventory before retrying.")

        let mcpIndex = #expect(throws: ExactWindowSelectorResolutionError.self) {
            _ = try ExactWindowSelectorResolver.select(
                from: [window],
                selection: .index(7),
                operation: "Window test",
                vocabulary: .mcp)
        }
        #expect(mcpIndex?.message ==
            "Window test window index 7 is not present. Refresh the inventory and select a window_id.")
    }

    @Test
    func `negative index refuses before candidate selection`() {
        let error = #expect(throws: ExactWindowSelectorResolutionError.self) {
            _ = try ExactWindowSelectorResolver.select(
                from: [],
                selection: .index(-1),
                operation: "Capture window selection",
                vocabulary: .mcp)
        }

        #expect(error?.message == "Capture window selection window index must be zero or greater.")
    }

    @Test
    func `WindowTarget adapter retains compatibility selection`() {
        #expect(ExactWindowSelectorResolver.selection(for: .application("Preview")) == .automatic)
        #expect(ExactWindowSelectorResolver.selection(for: .frontmost) == .automatic)
        #expect(ExactWindowSelectorResolver.selection(for: .title("Draft")) == .title("Draft"))
        #expect(ExactWindowSelectorResolver.selection(
            for: .applicationAndTitle(app: "Preview", title: "Draft")) == .title("Draft"))
        #expect(ExactWindowSelectorResolver.selection(for: .index(app: "Preview", index: 3)) == .index(3))
        #expect(ExactWindowSelectorResolver.selection(for: .windowId(42)) == .id(42))
    }
}
