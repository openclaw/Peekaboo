import AppKit
import Foundation
import PeekabooFoundation

/// Focus alone needs AX/foreground evidence; ordinary exact-ID listings remain geometry-only.
@MainActor
struct WindowFocusReadback {
    let catalog: WindowCGInfoLookup
    var processStartIdentity: (pid_t) -> UInt64? = SystemIdentityResolver.processStartIdentity
    var windowIdentity: (CGWindowID) -> SystemWindowIdentity? = SystemIdentityResolver.windowIdentity
    var focusedWindowID: (pid_t, TimeInterval) async throws -> CGWindowID? = { pid, timeout in
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return WindowIdentityService().focusedWindowID(for: app, timeout: timeout)
    }

    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var now: () -> ContinuousClock.Instant = { ContinuousClock.now }

    func validateIdentity(_ expected: WindowMutationIdentity) throws {
        guard let bounds = expected.capturedBounds,
              SystemIdentityResolver.validateWindowMutationIdentity(
                  expected,
                  expectedBounds: bounds,
                  processStartIdentityProvider: self.processStartIdentity,
                  windowIdentityProvider: { windowID in
                      guard let current = self.windowIdentity(windowID),
                            current.windowID == windowID else { return nil }
                      return current
                  })
        else {
            throw PeekabooError.commandFailed("Window \(expected.windowID) changed identity during focus")
        }
    }

    func capture(expectedIdentity: WindowMutationIdentity) async throws -> ServiceWindowInfo {
        try Task.checkCancellation()
        let deadline = self.now().advanced(by: .seconds(1))
        try self.validateIdentity(expectedIdentity)
        guard let window = self.catalog.serviceWindowInfo(windowID: expectedIdentity.windowID),
              let identity = window.mutationIdentity,
              identity.hasSameStableReceipt(as: expectedIdentity),
              window.bounds == expectedIdentity.capturedBounds,
              identity.capturedBounds == window.bounds,
              !window.isMinimized
        else {
            throw FocusError.focusVerificationFailed(CGWindowID(expectedIdentity.windowID))
        }
        // Fresh app and child AX wrappers each carry a bounded native messaging timeout.
        let focusedID = try await self.focusedWindowID(expectedIdentity.ownerProcessIdentifier, 0.1)
        let foregroundPID = self.frontmostPID()
        try self.validateIdentity(expectedIdentity)
        try Task.checkCancellation()
        guard self.now() < deadline else {
            throw FocusError.focusVerificationTimeout(CGWindowID(expectedIdentity.windowID))
        }
        guard FocusManagementService.isVerifiedFocus(
            targetWindowID: CGWindowID(expectedIdentity.windowID),
            ownerPID: expectedIdentity.ownerProcessIdentifier,
            focusedWindowID: focusedID,
            frontmostPID: foregroundPID)
        else {
            throw FocusError.focusVerificationFailed(CGWindowID(expectedIdentity.windowID))
        }

        return ServiceWindowInfo(
            windowID: window.windowID,
            title: window.title,
            bounds: window.bounds,
            isMinimized: window.isMinimized,
            isMainWindow: window.isMainWindow,
            isKeyWindow: focusedID.map(Int.init) == window.windowID,
            isFrontmost: foregroundPID == identity.ownerProcessIdentifier,
            windowLevel: window.windowLevel,
            alpha: window.alpha,
            index: window.index,
            isOffScreen: window.isOffScreen,
            layer: window.layer,
            isOnScreen: window.isOnScreen,
            sharingState: window.sharingState,
            mutationIdentity: identity)
    }
}
