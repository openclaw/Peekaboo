import CoreGraphics
import XCTest
@testable import PeekabooAutomationKit

final class ElementDetectionExactWindowOwnerTests: XCTestCase {
    func testExactWindowOnlyContextResolvesStableOwnerInsteadOfFrontmostApplication() {
        let identity = Self.identity(owner: 4242)

        let owner = ElementDetectionWindowResolver.stableExactWindowOwner(
            windowID: 707,
            receipt: nil,
            windowIdentityProvider: { _ in identity },
            processStartIdentityProvider: { _ in 11 })

        XCTAssertEqual(owner, 4242)
    }

    func testExactWindowOwnerRejectsOwnerChangeDuringResolution() {
        var identities = [Self.identity(owner: 4242), Self.identity(owner: 9001)]

        let owner = ElementDetectionWindowResolver.stableExactWindowOwner(
            windowID: 707,
            receipt: nil,
            windowIdentityProvider: { _ in identities.removeFirst() },
            processStartIdentityProvider: { _ in 11 })

        XCTAssertNil(owner)
    }

    func testExactWindowOwnerRejectsProcessGenerationChangeDuringResolution() {
        let identity = Self.identity(owner: 4242)
        var generations: [UInt64] = [11, 12]

        let owner = ElementDetectionWindowResolver.stableExactWindowOwner(
            windowID: 707,
            receipt: nil,
            windowIdentityProvider: { _ in identity },
            processStartIdentityProvider: { _ in generations.removeFirst() })

        XCTAssertNil(owner)
    }

    func testExactWindowOwnerRejectsMismatchedCaptureReceipt() {
        let identity = Self.identity(owner: 4242)
        let receipt = WindowMutationIdentity(
            windowID: 707,
            ownerProcessIdentifier: 4242,
            ownerProcessStartIdentity: 99,
            capturedBounds: identity.bounds)

        let owner = ElementDetectionWindowResolver.stableExactWindowOwner(
            windowID: 707,
            receipt: receipt,
            windowIdentityProvider: { _ in identity },
            processStartIdentityProvider: { _ in 11 })

        XCTAssertNil(owner)
    }

    private static func identity(owner: pid_t) -> SystemWindowIdentity {
        SystemWindowIdentity(
            windowID: 707,
            ownerProcessIdentifier: owner,
            title: "Fixture",
            bounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            layer: 0,
            alpha: 1,
            isOnScreen: true,
            sharingState: .readOnly)
    }
}
