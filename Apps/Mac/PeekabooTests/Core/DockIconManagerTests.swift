import AppKit
import Testing
@testable import Peekaboo

@Suite(.tags(.ui, .unit), .disabled("Requires AppKit/NSApplication which may hang in tests"))
@MainActor
struct DockIconManagerTests {
    var manager: DockIconManager!
    var settings: PeekabooSettings!

    @Test(.disabled("Requires NSApplication"))
    mutating func `Dock icon is shown by default when setting is true`() async {
        await self.setup()
        self.settings.showInDock = true
        self.manager.updateDockVisibility()
        #expect(NSApp.activationPolicy() == .regular)
    }

    @Test(.disabled("Requires NSApplication"))
    mutating func `Dock icon is hidden by default when setting is false`() async {
        await self.setup()
        self.settings.showInDock = false
        self.manager.updateDockVisibility()
        #expect(NSApp.activationPolicy() == .accessory)
    }

    @Test(.disabled("Requires NSApplication"))
    mutating func `Dock icon is shown when a window is visible, regardless of setting`() async {
        await self.setup()
        self.settings.showInDock = false
        self.manager.updateDockVisibility()
        #expect(NSApp.activationPolicy() == .accessory, "Precondition: Dock icon should be hidden")

        // Simulate opening a window
        let window = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        window.makeKeyAndOrderFront(nil)

        self.manager.updateDockVisibility()

        #expect(NSApp.activationPolicy() == .regular, "Dock icon should be visible when a window is open")

        window.close()
        self.manager.updateDockVisibility()
        #expect(NSApp.activationPolicy() == .accessory, "Dock icon should hide again after window is closed")
    }

    @Test(.disabled("Requires NSApplication"))
    mutating func `Temporarily showing dock works`() async {
        await self.setup()
        self.settings.showInDock = false
        self.manager.updateDockVisibility()
        #expect(NSApp.activationPolicy() == .accessory, "Precondition: Dock icon should be hidden")

        self.manager.temporarilyShowDock()
        #expect(NSApp.activationPolicy() == .regular, "Dock icon should be temporarily visible")
    }

    private mutating func setup() async {
        _ = NSApplication.shared
        self.manager = DockIconManager.shared
        // Use a temporary, non-shared settings instance for testing
        self.settings = makeTestSettings()
        self.manager.connectToSettings(self.settings)
    }
}
