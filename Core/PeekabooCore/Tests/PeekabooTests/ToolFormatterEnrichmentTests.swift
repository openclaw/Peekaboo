import Testing
@testable import PeekabooAgentRuntime

@Suite("Tool formatter enrichment")
struct ToolFormatterEnrichmentTests {
    private let registry = ToolFormatterRegistry()

    @Test
    func `list menus supports item and menu structure results`() {
        let formatter = self.registry.formatter(for: .listMenus)

        #expect(formatter.formatResultSummary(result: [
            "items": [["enabled": true]],
            "menu": "File",
            "app": "Safari",
        ]) == "→ 1 menu item in File menu for Safari [1 enabled]")
        #expect(formatter.formatResultSummary(result: [
            "menus": [[:], [:], [:], [:]],
            "app": "Safari",
            "totalItems": 28,
        ]) == "→ 4 menus for Safari (28 items)")
        #expect(formatter.formatResultSummary(result: [
            "menuCount": 1,
            "appName": "Finder",
        ]) == "→ 1 menu for Finder")
        #expect(formatter.formatResultSummary(result: [
            "menus": [[:], [:], [:], [:]],
            "totalItems": 28,
        ]) == "→ 4 menus (28 items)")
        #expect(formatter.formatResultSummary(result: [:]).isEmpty)
    }

    @Test
    func `menu click supports alternate results and compact arguments`() {
        let formatter = self.registry.formatter(for: .menuClick)

        #expect(formatter.formatResultSummary(result: ["clicked": "PDF"]) == "→ Clicked menu \"PDF\"")
        #expect(formatter.formatResultSummary(result: ["path": "Edit > Copy"]) ==
            "→ Clicked menu \"Edit → Copy\"")
        #expect(formatter.formatResultSummary(result: [
            "menuPath": ["File", "Export", "PDF"],
            "clicked": "ignored",
            "app": "Preview",
            "shortcut": "cmd+shift+p",
        ]) == "→ Clicked menu \"File → Export → PDF\" in Preview [shortcut: ⌘⇧p]")
        #expect(formatter.formatCompactSummary(arguments: ["path": " File > Export > PDF "]) ==
            "File → Export → PDF")
        #expect(formatter.formatCompactSummary(arguments: ["menu": "Edit", "item": "Copy"]) == "Edit → Copy")
        #expect(formatter.formatCompactSummary(arguments: ["menu": "Edit"]) == "Edit")
        #expect(formatter.formatCompactSummary(arguments: [:]).isEmpty)
        #expect(self.registry.formatter(for: .listMenus).formatCompactSummary(arguments: ["appName": "Safari"]) ==
            "for Safari")
    }

    @Test
    func `screenshot supports nested size dimensions`() {
        let formatter = self.registry.formatter(for: .screenshot)

        #expect(formatter.formatResultSummary(result: [
            "size": ["width": 1440, "height": 900],
        ]) == "→ Screenshot saved (1440×900px)")
        #expect(formatter.formatResultSummary(result: [
            "path": "/tmp/shot.png",
            "size": ["width": 1440.0, "height": 900.0],
        ]) == "→ shot.png (1440×900px)")
        #expect(formatter.formatResultSummary(result: ["size": "2 MB"]) == "→ Screenshot saved (2 MB)")
    }

    @Test
    func `see prefers description and labels unknown element types`() {
        let formatter = self.registry.formatter(for: .see)

        #expect(formatter.formatResultSummary(result: [
            "description": "Login dialog",
            "elements": [[:], ["type": "unknown"]],
        ]) == "→ Login dialog • [2 elements]")
        #expect(formatter.formatResultSummary(result: [
            "description": "Toolbar",
            "elements": [["type": "button"], ["type": "button"], ["type": "button"]],
        ]) == "→ Toolbar • [3 button]")
    }

    @Test
    func `analyze summarizes text without generic fallback`() {
        let formatter = self.registry.formatter(for: .analyze)

        #expect(formatter.formatResultSummary(result: ["text": "A login form with two fields"]) ==
            "→ \"A login form with two fields\"")
        #expect(formatter.formatResultSummary(result: ["count": 2]).isEmpty)
    }

    @Test
    func `application lifecycle uses app name and suppresses generic fallback`() {
        #expect(self.registry.formatter(for: .quitApp).formatResultSummary(result: ["app": "Safari"]) ==
            "→ Quit Safari")
        #expect(self.registry.formatter(for: .focusApp).formatResultSummary(result: ["appName": "Safari"]) ==
            "→ Focused Safari")
        #expect(self.registry.formatter(for: .hideApp).formatResultSummary(result: ["application": "Safari"]) ==
            "→ Hid Safari")
        #expect(self.registry.formatter(for: .unhideApp).formatResultSummary(result: ["app": "Safari"]) ==
            "→ Showed Safari")
        #expect(self.registry.formatter(for: .switchApp).formatResultSummary(result: ["app": "Safari"]) ==
            "→ Switched to Safari")
        #expect(self.registry.formatter(for: .quitApp).formatResultSummary(result: ["count": 1]).isEmpty)
    }

    @Test
    func `list windows suppresses unknown app and preserves real app detail`() {
        let formatter = self.registry.formatter(for: .listWindows)

        #expect(formatter.formatResultSummary(result: ["windows": [[:]]]) == "→ 1 window")
        #expect(formatter.formatResultSummary(result: [
            "windows": [
                ["app": "Safari", "title": "Docs"],
                ["app": "Safari", "title": "Settings"],
            ],
        ]) == "→ 2 windows for Safari • \"Docs\", \"Settings\"")
        #expect(formatter.formatResultSummary(result: ["count": 2, "app": "Unknown"]) == "→ 2 windows")
    }

    @Test
    func `list screens shows single resolution and suppresses missing total`() {
        let formatter = self.registry.formatter(for: .listScreens)

        #expect(formatter.formatResultSummary(result: [
            "screens": [["resolution": ["width": 1440, "height": 900]]],
        ]) == "→ 1 screen (1440×900)")
        #expect(formatter.formatResultSummary(result: [
            "screens": [["resolution": "1440 x 900"]],
        ]) == "→ 1 screen (1440×900)")
        #expect(formatter.formatResultSummary(result: [
            "screens": [
                ["width": 0, "height": 0],
                ["width": 0, "height": 0],
            ],
        ]) == "→ 2 screens")
        #expect(formatter.formatResultSummary(result: ["screens": [["name": "One"], ["name": "Two"]]]) ==
            "→ 2 screens")
    }

    @Test
    func `list spaces reports spaces containing windows`() {
        let formatter = self.registry.formatter(for: .listSpaces)

        #expect(formatter.formatResultSummary(result: [
            "spaces": [
                ["hasWindows": true],
                ["hasWindows": false],
                ["hasWindows": true],
            ],
        ]) == "→ 3 spaces (2 with windows)")
        #expect(formatter.formatResultSummary(result: [
            "spaces": [["hasWindows": false]],
        ]) == "→ 1 space")
    }

    @Test
    func `inspect ui reports element counts only`() {
        let formatter = self.registry.formatter(for: .inspectUI)

        #expect(formatter.formatResultSummary(result: ["count": 42]) == "→ 42 elements")
        #expect(formatter.formatResultSummary(result: ["elementCount": 1]) == "→ 1 element")
        #expect(formatter.formatResultSummary(result: ["elements": [[:], [:]]]) == "→ 2 elements")
        #expect(formatter.formatResultSummary(result: [:]).isEmpty)
    }

    @Test
    func `base formatter pluralizes generic item count`() {
        let formatter = BaseToolFormatter(toolType: .wait)

        #expect(formatter.formatResultSummary(result: ["count": 1]) == "→ 1 item")
        #expect(formatter.formatResultSummary(result: ["count": 2]) == "→ 2 items")
    }

    @Test
    func `clipboard summarizes reads writes and clears`() {
        let formatter = self.registry.formatter(for: .clipboard)

        #expect(formatter.formatResultSummary(result: ["result": "hello from clipboard"]) ==
            "→ \"hello from clipboard\"")
        #expect(formatter.formatResultSummary(result: ["result": "Set clipboard (public.utf8-plain-text, 5 bytes)"]) ==
            "→ Copied to clipboard")
        #expect(formatter.formatResultSummary(result: ["result": "Cleared clipboard."]) ==
            "→ Clipboard cleared")
        #expect(formatter.formatResultSummary(result: ["action": "get", "content": "read value"]) ==
            "→ \"read value\"")
        #expect(formatter.formatResultSummary(result: [:]).isEmpty)
    }

    @Test
    func `untouched formatter outputs remain stable`() {
        #expect(self.registry.formatter(for: .windowCapture).formatResultSummary(result: [
            "app": "Safari",
            "windowTitle": "Docs",
        ]) == "→ Safari \"Docs\"")
        #expect(self.registry.formatter(for: .dockLaunch).formatResultSummary(result: ["app": "Preview"]) ==
            "→ launched Preview from dock")
        #expect(self.registry.formatter(for: .shell).formatResultSummary(result: [
            "exitCode": 0,
            "command": "pwd",
        ]) == "→ Success \"pwd\"")
    }
}
