import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import Testing
@testable import PeekabooAgentRuntime

struct BrowserNativeWindowReceiptTests {
    private static let target = BrowserNativeWindowTarget(
        processIdentifier: 4242,
        processStartIdentity: 9001,
        windowID: 313)
    private static let bounds = CGRect(x: 40, y: 80, width: 1200, height: 800)

    @Test
    func `capture binds exact process generation window and bounds`() throws {
        let providers = Self.providers()

        let receipt = try BrowserNativeWindowReceiptResolver.capture(
            target: Self.target,
            providers: providers).get()

        #expect(receipt.target == Self.target)
        #expect(receipt.windowIdentity == Self.mutationIdentity())
        #expect(receipt.bounds == Self.bounds)
    }

    @Test
    func `capture refuses pid reuse`() {
        let providers = Self.providers(processStartIdentity: Self.target.processStartIdentity + 1)

        #expect(BrowserNativeWindowReceiptResolver.capture(
            target: Self.target,
            providers: providers) == .failure(.processGenerationChanged(
            processIdentifier: Self.target.processIdentifier,
            expected: Self.target.processStartIdentity,
            actual: Self.target.processStartIdentity + 1)))
    }

    @Test
    func `capture refuses replacement owner`() {
        let replacementPID: pid_t = 8888
        let providers = Self.providers(windowOwner: replacementPID)

        #expect(BrowserNativeWindowReceiptResolver.capture(
            target: Self.target,
            providers: providers) == .failure(.windowReplaced(
            windowID: Self.target.windowID,
            expectedOwner: Self.target.processIdentifier,
            actualOwner: replacementPID)))
    }

    @Test
    func `capture refuses a window that disappears`() {
        let providers = Self.providers(windowAvailable: false)

        #expect(BrowserNativeWindowReceiptResolver.capture(
            target: Self.target,
            providers: providers) == .failure(.windowUnavailable(Self.target.windowID)))
    }

    @Test
    func `capture refuses bounds drift during receipt acquisition`() {
        let drifted = Self.bounds.offsetBy(dx: 10, dy: 0)
        let providers = Self.providers(receiptBounds: drifted)

        #expect(BrowserNativeWindowReceiptResolver.capture(
            target: Self.target,
            providers: providers) == .failure(.boundsChanged(
            windowID: Self.target.windowID,
            expected: Self.bounds,
            actual: drifted)))
    }

    @Test
    func `capture refuses malformed target and receipt evidence`() {
        let invalidTarget = BrowserNativeWindowTarget(
            processIdentifier: 0,
            processStartIdentity: Self.target.processStartIdentity,
            windowID: Self.target.windowID)
        #expect(BrowserNativeWindowReceiptResolver.capture(
            target: invalidTarget,
            providers: Self.providers()) == .failure(.invalidProcessIdentifier(0)))

        let missingBounds = Self.providers(receiptIncludesBounds: false)
        #expect(BrowserNativeWindowReceiptResolver.capture(
            target: Self.target,
            providers: missingBounds) == .failure(.receiptMalformed(Self.target.windowID)))
    }

    @Test
    func `capture refuses a final identity race`() {
        let providers = Self.providers(validatesIdentity: false)

        #expect(BrowserNativeWindowReceiptResolver.capture(
            target: Self.target,
            providers: providers) == .failure(.identityChangedDuringCapture(Self.target.windowID)))
    }

    @Test
    func `revalidation returns the original immutable receipt`() throws {
        let receipt = Self.receipt()

        let revalidated = try BrowserNativeWindowReceiptResolver.revalidate(
            receipt,
            providers: Self.providers(windowMutationIdentity: { _ in
                Issue.record("Revalidation must not recapture or repin window authority")
                return nil
            })).get()

        #expect(revalidated == receipt)
    }

    @Test
    func `revalidation refuses pid reuse disappearance replacement and bounds drift`() {
        let receipt = Self.receipt()
        let reusedGeneration = Self.target.processStartIdentity + 1
        #expect(BrowserNativeWindowReceiptResolver.revalidate(
            receipt,
            providers: Self.providers(processStartIdentity: reusedGeneration)) ==
            .failure(.processGenerationChanged(
                processIdentifier: Self.target.processIdentifier,
                expected: Self.target.processStartIdentity,
                actual: reusedGeneration)))

        #expect(BrowserNativeWindowReceiptResolver.revalidate(
            receipt,
            providers: Self.providers(windowAvailable: false)) ==
            .failure(.windowUnavailable(Self.target.windowID)))

        let replacementPID: pid_t = 8888
        #expect(BrowserNativeWindowReceiptResolver.revalidate(
            receipt,
            providers: Self.providers(windowOwner: replacementPID)) ==
            .failure(.windowReplaced(
                windowID: Self.target.windowID,
                expectedOwner: Self.target.processIdentifier,
                actualOwner: replacementPID)))

        let drifted = Self.bounds.offsetBy(dx: 0, dy: 10)
        #expect(BrowserNativeWindowReceiptResolver.revalidate(
            receipt,
            providers: Self.providers(windowBounds: drifted)) ==
            .failure(.boundsChanged(
                windowID: Self.target.windowID,
                expected: Self.bounds,
                actual: drifted)))
    }

    @Test
    func `revalidation refuses malformed authority and final race without repinning`() {
        let malformed = BrowserNativeWindowReceipt(
            target: Self.target,
            windowIdentity: Self.mutationIdentity(bounds: Self.bounds.offsetBy(dx: 1, dy: 0)),
            bounds: Self.bounds)
        #expect(BrowserNativeWindowReceiptResolver.revalidate(
            malformed,
            providers: Self.providers()) == .failure(.receiptMalformed(Self.target.windowID)))

        #expect(BrowserNativeWindowReceiptResolver.revalidate(
            Self.receipt(),
            providers: Self.providers(validatesIdentity: false)) ==
            .failure(.identityChangedDuringRevalidation(Self.target.windowID)))
    }

    private static func providers(
        processStartIdentity: UInt64? = target.processStartIdentity,
        windowAvailable: Bool = true,
        windowOwner: pid_t = target.processIdentifier,
        windowBounds: CGRect = bounds,
        receiptBounds: CGRect = bounds,
        receiptIncludesBounds: Bool = true,
        validatesIdentity: Bool = true,
        windowMutationIdentity: (@Sendable (CGWindowID) -> WindowMutationIdentity?)? = nil)
        -> BrowserNativeWindowReceiptResolver.Providers
    {
        BrowserNativeWindowReceiptResolver.Providers(
            processStartIdentity: { _ in processStartIdentity },
            windowIdentity: { windowID in
                guard windowAvailable else { return nil }
                return SystemWindowIdentity(
                    windowID: windowID,
                    ownerProcessIdentifier: windowOwner,
                    ownerProcessStartIdentity: processStartIdentity,
                    title: "ignored title",
                    bounds: windowBounds,
                    layer: 0,
                    alpha: 1,
                    isOnScreen: true,
                    sharingState: .readOnly)
            },
            windowMutationIdentity: windowMutationIdentity ?? { _ in
                Self.mutationIdentity(
                    owner: windowOwner,
                    generation: processStartIdentity ?? 0,
                    bounds: receiptIncludesBounds ? receiptBounds : nil)
            },
            validateWindowMutationIdentity: { _ in validatesIdentity })
    }

    private static func mutationIdentity(
        owner: pid_t = target.processIdentifier,
        generation: UInt64 = target.processStartIdentity,
        bounds: CGRect? = bounds) -> WindowMutationIdentity
    {
        WindowMutationIdentity(
            windowID: Int(self.target.windowID),
            ownerProcessIdentifier: owner,
            ownerProcessStartIdentity: generation,
            capturedBounds: bounds,
            isMinimized: false)
    }

    private static func receipt() -> BrowserNativeWindowReceipt {
        BrowserNativeWindowReceipt(
            target: self.target,
            windowIdentity: self.mutationIdentity(),
            bounds: self.bounds)
    }
}
