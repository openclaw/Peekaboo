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

    @Test
    func `Stable window identity binds generation while allowing descriptive metadata refresh`() throws {
        let before = Self.identity(title: "Before", applicationName: "Old Name")
        let after = Self.identity(title: "After", applicationName: "New Name")
        var identities = [before, after]
        var generations: [UInt64] = [111, 111]

        let identity = try #require(SystemIdentityResolver.stableWindowIdentity(
            1790,
            windowIdentityProvider: { _ in identities.removeFirst() },
            processStartIdentityProvider: { _ in generations.removeFirst() }))

        #expect(identity.ownerProcessStartIdentity == 111)
        #expect(identity.title == "After")
        #expect(identity.applicationName == "New Name")
    }

    @Test
    func `Stable window identity rejects generation and safety fingerprint drift`() {
        let before = Self.identity()
        let changedBounds = Self.identity(bounds: CGRect(x: 561, y: 371, width: 673, height: 439))
        let changedOwner = Self.identity(ownerPID: 43)

        for after in [changedBounds, changedOwner] {
            var identities = [before, after]
            var generations: [UInt64] = [111, 111]
            #expect(SystemIdentityResolver.stableWindowIdentity(
                1790,
                windowIdentityProvider: { _ in identities.removeFirst() },
                processStartIdentityProvider: { _ in generations.removeFirst() }) == nil)
        }

        var stableIdentities = [before, before]
        var changedGenerations: [UInt64] = [111, 112]
        #expect(SystemIdentityResolver.stableWindowIdentity(
            1790,
            windowIdentityProvider: { _ in stableIdentities.removeFirst() },
            processStartIdentityProvider: { _ in changedGenerations.removeFirst() }) == nil)
    }

    private static func identity(
        ownerPID: pid_t = 42,
        title: String = "Fixture",
        bounds: CGRect = CGRect(x: 560, y: 371, width: 673, height: 439),
        applicationName: String = "Fixture App") -> SystemWindowIdentity
    {
        SystemWindowIdentity(
            windowID: 1790,
            ownerProcessIdentifier: ownerPID,
            title: title,
            bounds: bounds,
            layer: 0,
            alpha: 1,
            isOnScreen: true,
            sharingState: .readWrite,
            applicationName: applicationName)
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
