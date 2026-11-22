import CoreGraphics
import Testing
@testable import PeekabooAutomationKit

struct BoundedAXWindowIdentityScannerTests {
    @Test
    func `many-child scan stops at aggregate deadline and resets each child timeout`() {
        var remainingTimeouts: [Float?] = [0.1, 0.04, nil]
        var probed: [Int] = []
        var timeoutEvents: [(Int, Float)] = []

        let result = BoundedAXWindowIdentityScanner.scanWindows(
            Array(0..<100),
            remainingTimeout: { remainingTimeouts.removeFirst() },
            applyTimeout: { window, timeout in timeoutEvents.append((window, timeout)) },
            snapshot: { window in
                probed.append(window)
                return nil
            })

        #expect(result == nil)
        #expect(probed == [0, 1])
        #expect(timeoutEvents.map(\.0) == [0, 0, 1, 1])
        #expect(timeoutEvents.map(\.1) == [0.1, 0, 0.04, 0])
        #expect(remainingTimeouts.isEmpty)
        #expect(BoundedAXWindowIdentityScanner.callTimeout(remainingSeconds: 0) == nil)
        #expect(BoundedAXWindowIdentityScanner.callTimeout(remainingSeconds: 0.004) == 0.004)
        #expect(BoundedAXWindowIdentityScanner.callTimeout(remainingSeconds: 0.04) == 0.04)
        #expect(BoundedAXWindowIdentityScanner.callTimeout(remainingSeconds: 1) == 0.1)
    }

    @Test
    func `a missing accessibility position or size is not stored as a zero rectangle`() {
        let reported = CGRect(x: 12, y: 34, width: 200, height: 80)
        #expect(
            BoundedAXWindowIdentityScanner.reportedWindowBounds(
                position: reported.origin,
                size: reported.size) == reported)
        #expect(
            BoundedAXWindowIdentityScanner.reportedWindowBounds(
                position: .zero,
                size: CGSize(width: 20, height: 20)) == CGRect(x: 0, y: 0, width: 20, height: 20))
        #expect(
            BoundedAXWindowIdentityScanner.reportedWindowBounds(
                position: nil,
                size: reported.size) == nil)
        #expect(
            BoundedAXWindowIdentityScanner.reportedWindowBounds(
                position: reported.origin,
                size: nil) == nil)
        #expect(BoundedAXWindowIdentityScanner.reportedWindowBounds(position: nil, size: nil) == nil)
    }

    @Test
    func `a missing accessibility rectangle keeps title and minimized state`() throws {
        let partial = BoundedAXWindowIdentityScanner.identitySnapshot(
            receipt: BoundedAXWindowScanReceipt(
                windowID: 7,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 9),
            title: "Notes",
            bounds: nil,
            isMinimized: true)
        #expect(partial.bounds == nil)
        #expect(partial.title == "Notes")
        #expect(partial.isMinimized)
        #expect(partial.windowRequiringCompleteBounds() == nil)

        let reported = CGRect(x: 12, y: 34, width: 200, height: 80)
        let complete = BoundedAXWindowIdentityScanner.identitySnapshot(
            receipt: BoundedAXWindowScanReceipt(
                windowID: 7,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 9),
            title: "Notes",
            bounds: reported,
            isMinimized: true)
        #expect(complete.bounds == reported)
        let axOnly = try #require(complete.windowRequiringCompleteBounds())
        #expect(axOnly.bounds == reported)
        #expect(axOnly.title == "Notes")
        #expect(axOnly.isMinimized)
        #expect(axOnly.mutationIdentity?.capturedBounds == reported)
        #expect(axOnly.mutationIdentity?.isMinimized == true)

        let coreGraphicsBounds = CGRect(x: 12, y: 34, width: 200, height: 80)
        let identity = WindowMutationIdentity(
            windowID: 924,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 7,
            capturedBounds: coreGraphicsBounds,
            isMinimized: false)
        let cgWindow = ServiceWindowInfo(
            windowID: 924,
            title: "WindowServer",
            bounds: coreGraphicsBounds,
            isOffScreen: true,
            isOnScreen: false,
            mutationIdentity: identity)
        let enriched = cgWindow.withExactAXState(partial)
        #expect(enriched.bounds == coreGraphicsBounds)
        #expect(enriched.title == "Notes")
        #expect(enriched.isMinimized)
        let receipt = try #require(enriched.mutationIdentity)
        #expect(receipt.capturedBounds == coreGraphicsBounds)
        #expect(receipt.isMinimized == true)
        #expect(receipt.processIdentity == identity.processIdentity)
    }
}
