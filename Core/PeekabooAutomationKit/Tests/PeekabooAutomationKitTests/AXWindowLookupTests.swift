import ApplicationServices
import CoreGraphics
import Testing
@testable import PeekabooAutomationKit

struct AXWindowLookupTests {
    private let application = AXUIElementCreateApplication(-100)
    private let enumerated = AXUIElementCreateApplication(-101)
    private let focused = AXUIElementCreateApplication(-102)
    private let main = AXUIElementCreateApplication(-103)

    @Test
    func `empty AXWindows resolves the exact focused window without reading main`() throws {
        var attributes: [String] = []
        let lookup = self.lookup { _, name in
            attributes.append(name)
            return name == kAXFocusedWindowAttribute ? self.focused : self.main
        }

        let window = try #require(lookup.findWindow(byID: 42))
        #expect(CFEqual(window, self.focused))
        #expect(attributes == [kAXFocusedWindowAttribute])
    }

    @Test
    func `a different focused window does not substitute for the requested ID`() {
        var lookup = self.lookup { _, name in name == kAXFocusedWindowAttribute ? self.focused : nil }
        lookup.windowID = { _ in 99 }

        #expect(lookup.findWindow(byID: 42) == nil)
    }

    @Test(arguments: [false, true])
    func `main window resolves after missing or unrelated focus`(hasFocus: Bool) throws {
        var attributes: [String] = []
        var lookup = self.lookup { _, name in
            attributes.append(name)
            return name == kAXMainWindowAttribute ? self.main : (hasFocus ? self.focused : nil)
        }
        lookup.windowID = { CFEqual($0, self.main) ? 42 : 99 }

        let window = try #require(lookup.findWindow(byID: 42))
        #expect(CFEqual(window, self.main))
        #expect(attributes == [kAXFocusedWindowAttribute, kAXMainWindowAttribute])
    }

    @Test
    func `AXWindows hit is preferred without any focused or main reads`() throws {
        let lookup = self.lookup { _, _ in
            Issue.record("A primary hit must not query fallback attributes")
            return self.focused
        }

        let window = try #require(lookup.findWindow(byID: 42, among: [self.enumerated]))
        #expect(CFEqual(window, self.enumerated))
    }

    @Test
    func `an unrelated enumerated window does not hide the exact focused window`() throws {
        var lookup = self.lookup { _, _ in self.focused }
        lookup.windowID = { CFEqual($0, self.enumerated) ? 99 : 42 }

        let window = try #require(lookup.findWindow(byID: 42, among: [self.enumerated]))
        #expect(CFEqual(window, self.focused))
    }

    @Test(arguments: [pid_t?.none, .some(200)])
    func `exact native ID with missing or different owner is refused`(owner: pid_t?) {
        var lookup = self.lookup { _, _ in self.focused }
        lookup.ownerPID = { _ in owner }

        #expect(lookup.findWindow(byID: 42) == nil)
        #expect(lookup.additionalWindows(excluding: []).isEmpty)
    }

    @Test(arguments: [CGWindowID?.none, .some(0)])
    func `failed or zero native IDs cannot establish a fallback`(windowID: CGWindowID?) {
        var lookup = self.lookup { _, _ in self.focused }
        lookup.windowID = { _ in windowID }

        #expect(lookup.findWindow(byID: 42) == nil)
        #expect(lookup.additionalWindows(excluding: []).isEmpty)
    }

    @Test
    func `each resolution rereads both the application reference and native identity`() {
        var reference: AXUIElement? = self.focused
        var actualID: CGWindowID = 42
        var reads = 0
        var lookup = self.lookup { _, name in
            guard name == kAXFocusedWindowAttribute else { return nil }
            reads += 1
            return reference
        }
        lookup.windowID = { _ in actualID }

        #expect(lookup.findWindow(byID: 42) != nil)
        actualID = 99
        #expect(lookup.findWindow(byID: 42) == nil)
        actualID = 42
        reference = nil
        #expect(lookup.findWindow(byID: 42) == nil)
        #expect(reads == 3)
    }

    @Test
    func `malformed references and expired budgets fail closed`() {
        var lookup = self.lookup { _, _ in "not a window" as CFString }
        #expect(lookup.findWindow(byID: 42) == nil)

        lookup.messagingTimeout = { nil }
        lookup.readAttribute = { _, _ in
            Issue.record("Expired lookup must not read AX attributes")
            return self.focused
        }
        #expect(lookup.findWindow(byID: 42) == nil)
    }

    @Test
    func `inventory adds only distinct owned fallback IDs missing from AXWindows`() throws {
        var lookup = self.lookup { _, name in name == kAXFocusedWindowAttribute ? self.focused : self.main }
        lookup.windowID = { CFEqual($0, self.focused) ? 42 : 43 }

        let windows = lookup.additionalWindows(excluding: [42])
        #expect(windows.count == 1)
        let window = try #require(windows.first)
        #expect(CFEqual(window, self.main))

        lookup.windowID = { _ in 42 }
        #expect(lookup.additionalWindows(excluding: []).count == 1)
        #expect(lookup.additionalWindows(excluding: [42]).isEmpty)
    }

    private func lookup(
        readAttribute: @escaping (AXUIElement, String) -> CFTypeRef?) -> AXWindowLookup
    {
        AXWindowLookup(
            application: self.application,
            processIdentifier: 100,
            readAttribute: readAttribute,
            windowID: { _ in 42 },
            ownerPID: { _ in 100 })
    }
}
