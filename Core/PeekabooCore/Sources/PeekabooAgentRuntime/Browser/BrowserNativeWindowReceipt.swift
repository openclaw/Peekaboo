import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit

/// The native browser window selected by an authenticated browser connection.
///
/// A PID alone is not authority because macOS recycles process identifiers. Callers must carry the
/// process-start generation and one exact WindowServer identifier obtained from trusted discovery.
struct BrowserNativeWindowTarget: Equatable, Sendable {
    let processIdentifier: pid_t
    let processStartIdentity: UInt64
    let windowID: CGWindowID
}

/// Immutable capture-time authority for one native browser window.
struct BrowserNativeWindowReceipt: Equatable, Sendable {
    let target: BrowserNativeWindowTarget
    let windowIdentity: WindowMutationIdentity
    let bounds: CGRect
}

/// Typed reasons why native browser window authority could not be established or retained.
enum BrowserNativeWindowReceiptFailure: Error, Equatable, Sendable {
    case invalidProcessIdentifier(pid_t)
    case invalidProcessStartIdentity(UInt64)
    case invalidWindowIdentifier(CGWindowID)
    case processUnavailable(pid_t)
    case processGenerationChanged(processIdentifier: pid_t, expected: UInt64, actual: UInt64)
    case windowUnavailable(CGWindowID)
    case windowReplaced(windowID: CGWindowID, expectedOwner: pid_t, actualOwner: pid_t)
    case boundsChanged(windowID: CGWindowID, expected: CGRect, actual: CGRect)
    case receiptMalformed(CGWindowID)
    case identityChangedDuringCapture(CGWindowID)
    case identityChangedDuringRevalidation(CGWindowID)
}

/// Captures and revalidates native browser window authority using public process and WindowServer identity only.
///
/// Descriptive metadata such as titles is deliberately excluded. Revalidation never repins: a bounds change,
/// owner change, disappearance, or PID-generation change invalidates the original receipt.
enum BrowserNativeWindowReceiptResolver {
    private enum IdentityCheckPhase {
        case capture
        case revalidation

        func identityChangedFailure(_ windowID: CGWindowID) -> BrowserNativeWindowReceiptFailure {
            switch self {
            case .capture:
                .identityChangedDuringCapture(windowID)
            case .revalidation:
                .identityChangedDuringRevalidation(windowID)
            }
        }
    }

    struct Providers: Sendable {
        let processStartIdentity: @Sendable (pid_t) -> UInt64?
        let windowIdentity: @Sendable (CGWindowID) -> SystemWindowIdentity?
        let windowMutationIdentity: @Sendable (CGWindowID) -> WindowMutationIdentity?
        let validateWindowMutationIdentity: @Sendable (WindowMutationIdentity) -> Bool

        static let live = Providers(
            processStartIdentity: SystemIdentityResolver.processStartIdentity,
            windowIdentity: SystemIdentityResolver.windowIdentity,
            windowMutationIdentity: SystemIdentityResolver.windowMutationIdentity,
            validateWindowMutationIdentity: SystemIdentityResolver.validateWindowMutationIdentity)
    }

    static func capture(
        target: BrowserNativeWindowTarget,
        providers: Providers = .live) -> Result<BrowserNativeWindowReceipt, BrowserNativeWindowReceiptFailure>
    {
        if let failure = self.invalidTargetFailure(target) {
            return .failure(failure)
        }
        if let failure = self.currentIdentityFailure(
            target: target,
            expectedBounds: nil,
            phase: .capture,
            providers: providers)
        {
            return .failure(failure)
        }
        guard let initialWindow = providers.windowIdentity(target.windowID) else {
            return .failure(.windowUnavailable(target.windowID))
        }
        guard initialWindow.windowID == target.windowID else {
            return .failure(.identityChangedDuringCapture(target.windowID))
        }
        guard initialWindow.ownerProcessIdentifier == target.processIdentifier else {
            return .failure(.windowReplaced(
                windowID: target.windowID,
                expectedOwner: target.processIdentifier,
                actualOwner: initialWindow.ownerProcessIdentifier))
        }

        guard let identity = providers.windowMutationIdentity(target.windowID) else {
            return .failure(self.currentIdentityFailure(
                target: target,
                expectedBounds: initialWindow.bounds,
                phase: .capture,
                providers: providers) ?? .identityChangedDuringCapture(target.windowID))
        }
        guard identity.windowID == Int(target.windowID),
              identity.ownerProcessIdentifier == target.processIdentifier,
              identity.ownerProcessStartIdentity == target.processStartIdentity,
              let capturedBounds = identity.capturedBounds
        else {
            return .failure(self.identityMismatchFailure(
                identity,
                target: target,
                expectedBounds: initialWindow.bounds) ?? .receiptMalformed(target.windowID))
        }
        guard capturedBounds == initialWindow.bounds else {
            return .failure(.boundsChanged(
                windowID: target.windowID,
                expected: initialWindow.bounds,
                actual: capturedBounds))
        }
        guard providers.validateWindowMutationIdentity(identity) else {
            return .failure(self.currentIdentityFailure(
                target: target,
                expectedBounds: capturedBounds,
                phase: .capture,
                providers: providers) ?? .identityChangedDuringCapture(target.windowID))
        }

        return .success(BrowserNativeWindowReceipt(
            target: target,
            windowIdentity: identity,
            bounds: capturedBounds))
    }

    /// Returns the original receipt on success. It never creates or substitutes a new receipt.
    static func revalidate(
        _ receipt: BrowserNativeWindowReceipt,
        providers: Providers = .live) -> Result<BrowserNativeWindowReceipt, BrowserNativeWindowReceiptFailure>
    {
        let target = receipt.target
        if let failure = self.invalidTargetFailure(target) {
            return .failure(failure)
        }
        guard receipt.windowIdentity.windowID == Int(target.windowID),
              receipt.windowIdentity.ownerProcessIdentifier == target.processIdentifier,
              receipt.windowIdentity.ownerProcessStartIdentity == target.processStartIdentity,
              receipt.windowIdentity.capturedBounds == receipt.bounds
        else {
            return .failure(.receiptMalformed(target.windowID))
        }
        if let failure = self.currentIdentityFailure(
            target: target,
            expectedBounds: receipt.bounds,
            phase: .revalidation,
            providers: providers)
        {
            return .failure(failure)
        }
        guard providers.validateWindowMutationIdentity(receipt.windowIdentity) else {
            return .failure(self.currentIdentityFailure(
                target: target,
                expectedBounds: receipt.bounds,
                phase: .revalidation,
                providers: providers) ?? .identityChangedDuringRevalidation(target.windowID))
        }
        return .success(receipt)
    }

    private static func invalidTargetFailure(
        _ target: BrowserNativeWindowTarget) -> BrowserNativeWindowReceiptFailure?
    {
        guard target.processIdentifier > 0 else {
            return .invalidProcessIdentifier(target.processIdentifier)
        }
        guard target.processStartIdentity > 0 else {
            return .invalidProcessStartIdentity(target.processStartIdentity)
        }
        guard target.windowID != kCGNullWindowID else {
            return .invalidWindowIdentifier(target.windowID)
        }
        return nil
    }

    private static func currentIdentityFailure(
        target: BrowserNativeWindowTarget,
        expectedBounds: CGRect?,
        phase: IdentityCheckPhase,
        providers: Providers) -> BrowserNativeWindowReceiptFailure?
    {
        guard let currentGeneration = providers.processStartIdentity(target.processIdentifier) else {
            return .processUnavailable(target.processIdentifier)
        }
        guard currentGeneration == target.processStartIdentity else {
            return .processGenerationChanged(
                processIdentifier: target.processIdentifier,
                expected: target.processStartIdentity,
                actual: currentGeneration)
        }
        guard let currentWindow = providers.windowIdentity(target.windowID) else {
            return .windowUnavailable(target.windowID)
        }
        guard currentWindow.windowID == target.windowID else {
            return phase.identityChangedFailure(target.windowID)
        }
        guard currentWindow.ownerProcessIdentifier == target.processIdentifier else {
            return .windowReplaced(
                windowID: target.windowID,
                expectedOwner: target.processIdentifier,
                actualOwner: currentWindow.ownerProcessIdentifier)
        }
        if let expectedBounds, currentWindow.bounds != expectedBounds {
            return .boundsChanged(
                windowID: target.windowID,
                expected: expectedBounds,
                actual: currentWindow.bounds)
        }
        return nil
    }

    private static func identityMismatchFailure(
        _ identity: WindowMutationIdentity,
        target: BrowserNativeWindowTarget,
        expectedBounds: CGRect) -> BrowserNativeWindowReceiptFailure?
    {
        guard identity.windowID == Int(target.windowID) else {
            return .identityChangedDuringCapture(target.windowID)
        }
        guard identity.ownerProcessIdentifier == target.processIdentifier else {
            return .windowReplaced(
                windowID: target.windowID,
                expectedOwner: target.processIdentifier,
                actualOwner: identity.ownerProcessIdentifier)
        }
        guard identity.ownerProcessStartIdentity == target.processStartIdentity else {
            return .processGenerationChanged(
                processIdentifier: target.processIdentifier,
                expected: target.processStartIdentity,
                actual: identity.ownerProcessStartIdentity)
        }
        if let capturedBounds = identity.capturedBounds,
           capturedBounds != expectedBounds
        {
            return .boundsChanged(
                windowID: target.windowID,
                expected: expectedBounds,
                actual: capturedBounds)
        }
        return nil
    }
}
