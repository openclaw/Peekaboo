import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAutomationKit

struct SystemIdentityResolverTests {
    @Test
    func `Exact window identity can be selected from a full offscreen catalog`() throws {
        let expectedBounds = CGRect(x: 560, y: 371, width: 673, height: 439)
        let unrelated = Self.windowDictionary(
            windowID: 1789,
            ownerPID: 41,
            bounds: CGRect(x: 10, y: 20, width: 300, height: 200),
            isOnScreen: true)
        let minimized = Self.windowDictionary(
            windowID: 1790,
            ownerPID: 42,
            bounds: expectedBounds,
            isOnScreen: false)

        let identity = try #require(SystemIdentityResolver.windowIdentity(1790, in: [unrelated, minimized]))

        #expect(identity.windowID == 1790)
        #expect(identity.ownerProcessIdentifier == 42)
        #expect(identity.bounds == expectedBounds)
        #expect(identity.isOnScreen == false)
    }

    private static func windowDictionary(
        windowID: Int,
        ownerPID: Int,
        bounds: CGRect,
        isOnScreen: Bool) -> [String: Any]
    {
        [
            kCGWindowNumber as String: windowID,
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
            kCGWindowIsOnscreen as String: isOnScreen,
            kCGWindowLayer as String: 0,
            kCGWindowAlpha as String: 1,
        ]
    }
}
