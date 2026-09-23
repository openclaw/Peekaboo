import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAutomationKit

struct AXWindowIDResolverTests {
    private let element = AXUIElementCreateApplication(-101)
    private let window = AXUIElementCreateApplication(-102)

    @Test
    func `direct native window identity does not query an owning window`() {
        var linkedReads = 0
        let result = AXWindowIDResolver.owningWindowID(
            of: self.element,
            windowID: { _ in 42 },
            windowAttribute: { _ in
                linkedReads += 1
                return self.window
            })

        #expect(result == 42)
        #expect(linkedReads == 0)
    }

    @Test(arguments: [CGWindowID?.none, .some(0)])
    func `web content with no direct window identifier uses its AXWindow link`(direct: CGWindowID?) {
        var linkedReads = 0
        var lookedUpElements: [AXUIElement] = []
        let result = AXWindowIDResolver.owningWindowID(
            of: self.element,
            windowID: { element in
                lookedUpElements.append(element)
                return CFEqual(element, self.window) ? 42 : direct
            },
            windowAttribute: { element in
                #expect(CFEqual(element, self.element))
                linkedReads += 1
                return self.window
            })

        #expect(result == 42)
        #expect(linkedReads == 1)
        #expect(lookedUpElements.count == 2)
        #expect(CFEqual(lookedUpElements[0], self.element))
        #expect(CFEqual(lookedUpElements[1], self.window))
    }

    @Test(arguments: [CGWindowID?.none, .some(0)])
    func `missing or unresolved AXWindow never fabricates an identity`(linked: CGWindowID?) {
        #expect(AXWindowIDResolver.owningWindowID(
            of: self.element,
            windowID: { element in CFEqual(element, self.window) ? linked : nil },
            windowAttribute: { _ in self.window }) == nil)
    }

    @Test
    func `missing and malformed owning-window attributes are refused`() {
        for value: CFTypeRef? in [nil, "not an AX element" as CFString, kCFBooleanTrue] {
            var identifierReads = 0
            let result = AXWindowIDResolver.owningWindowID(
                of: self.element,
                windowID: { _ in
                    identifierReads += 1
                    return nil
                },
                windowAttribute: { _ in value })

            #expect(result == nil)
            #expect(identifierReads == 1)
        }
    }

    @Test
    func `owning window identity is not guessed from the expected target`() {
        let actualWindowID = AXWindowIDResolver.owningWindowID(
            of: self.element,
            windowID: { element in CFEqual(element, self.window) ? 99 : nil },
            windowAttribute: { _ in self.window })

        #expect(actualWindowID == 99)
        #expect(actualWindowID != 42)
    }
}
