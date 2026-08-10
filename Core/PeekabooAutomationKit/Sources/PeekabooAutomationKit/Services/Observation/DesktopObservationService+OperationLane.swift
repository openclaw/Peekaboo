import CoreGraphics
import Foundation

struct DesktopObservationLanePlan: Sendable {
    let scope: DesktopOperationScope
    let access: DesktopOperationAccess
    let expectedProcessIdentity: ApplicationProcessIdentity?
    let expectedWindowIdentity: WindowMutationIdentity?

    static let global = DesktopObservationLanePlan(
        scope: .global,
        access: .write,
        expectedProcessIdentity: nil,
        expectedWindowIdentity: nil)
}

extension DesktopObservationService {
    func withDesktopOperationLane<T: Sendable>(
        for request: DesktopObservationRequest,
        operation: @escaping @MainActor @Sendable (DesktopObservationLanePlan?) async throws -> T) async throws -> T
    {
        switch self.screenCapture.captureTransactionGateOwner {
        case .caller:
            let plan = self.operationLanePlan(for: request)
            return try await self.operationLaneCoordinator.run(scope: plan.scope, access: plan.access) {
                try self.validateCurrentLaneIdentity(plan)
                let result = try await operation(plan)
                try self.validateCurrentLaneIdentity(plan)
                return result
            }
        case .service:
            // IPC-backed services acquire desktop and capture lanes in the execution host. Holding
            // either client-side lane across the RPC would make the host wait on its own caller.
            return try await operation(nil)
        }
    }

    func operationLanePlan(for request: DesktopObservationRequest) -> DesktopObservationLanePlan {
        guard request.capture.focus == .background,
              !(request.detection.mode != .none && request.detection.allowWebFocusFallback)
        else {
            return .global
        }
        if case let .menubarPopover(_, openIfNeeded) = request.target, openIfNeeded != nil {
            return .global
        }

        switch request.target {
        case let .windowID(windowID):
            return self.exactWindowLanePlan(windowID: windowID) ?? .global
        case let .pid(processIdentifier, window):
            if case let .id(windowID)? = window,
               let plan = self.exactWindowLanePlan(windowID: windowID),
               plan.expectedProcessIdentity?.processIdentifier == processIdentifier
            {
                return plan
            }
            guard let processStartIdentity = self.processStartIdentityProvider(processIdentifier) else {
                return .global
            }
            let identity = ApplicationProcessIdentity(
                processIdentifier: processIdentifier,
                processStartIdentity: processStartIdentity)
            return DesktopObservationLanePlan(
                scope: .process(identity),
                access: .read,
                expectedProcessIdentity: identity,
                expectedWindowIdentity: nil)
        case let .app(_, window):
            guard case let .id(windowID)? = window else { return .global }
            return self.exactWindowLanePlan(windowID: windowID) ?? .global
        case .allScreens, .area, .frontmost, .menubar, .menubarPopover, .screen:
            return .global
        }
    }

    func validateResolvedTarget(
        _ target: ResolvedObservationTarget,
        for plan: DesktopObservationLanePlan?) throws
    {
        guard let plan else { return }
        if let expectedWindowIdentity = plan.expectedWindowIdentity {
            guard let resolvedApplication = target.app,
                  resolvedApplication.processIdentifier == expectedWindowIdentity.ownerProcessIdentifier,
                  resolvedApplication.processStartIdentity == expectedWindowIdentity.ownerProcessStartIdentity,
                  let context = target.detectionContext,
                  context.windowID == expectedWindowIdentity.windowID,
                  context.applicationProcessId == expectedWindowIdentity.ownerProcessIdentifier,
                  let resolvedWindowIdentity = context.windowMutationIdentity,
                  Self.sameWindowIdentity(resolvedWindowIdentity, expectedWindowIdentity)
            else {
                throw DesktopObservationError.targetChanged(
                    "the resolved exact window no longer matched its process-generation lane")
            }
            return
        }
        if let expectedProcessIdentity = plan.expectedProcessIdentity {
            guard let resolvedApplication = target.app,
                  resolvedApplication.processIdentifier == expectedProcessIdentity.processIdentifier,
                  resolvedApplication.processStartIdentity == expectedProcessIdentity.processStartIdentity,
                  target.detectionContext?.applicationProcessId == expectedProcessIdentity.processIdentifier
            else {
                throw DesktopObservationError.targetChanged(
                    "the resolved PID no longer matched its process-generation lane")
            }
        }
    }

    func validateCurrentLaneIdentity(_ plan: DesktopObservationLanePlan?) throws {
        guard let plan else { return }
        if let expectedWindowIdentity = plan.expectedWindowIdentity {
            guard let windowID = CGWindowID(exactly: expectedWindowIdentity.windowID),
                  let currentWindowIdentity = self.windowMutationIdentityProvider(windowID),
                  Self.sameWindowIdentity(currentWindowIdentity, expectedWindowIdentity)
            else {
                throw DesktopObservationError.targetChanged(
                    "the exact window owner, process generation, or bounds changed during observation")
            }
            return
        }
        if let expectedProcessIdentity = plan.expectedProcessIdentity,
           self.processStartIdentityProvider(expectedProcessIdentity.processIdentifier) !=
           expectedProcessIdentity.processStartIdentity
        {
            throw DesktopObservationError.targetChanged(
                "the target process generation changed during observation")
        }
    }

    private func exactWindowLanePlan(windowID: CGWindowID) -> DesktopObservationLanePlan? {
        guard let identity = self.windowMutationIdentityProvider(windowID),
              identity.capturedBounds != nil,
              self.processStartIdentityProvider(identity.ownerProcessIdentifier) ==
              identity.ownerProcessStartIdentity
        else {
            return nil
        }
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: identity.ownerProcessIdentifier,
            processStartIdentity: identity.ownerProcessStartIdentity)
        return DesktopObservationLanePlan(
            scope: .window(identity),
            access: .read,
            expectedProcessIdentity: processIdentity,
            expectedWindowIdentity: identity)
    }

    private static func sameWindowIdentity(
        _ lhs: WindowMutationIdentity,
        _ rhs: WindowMutationIdentity) -> Bool
    {
        lhs.windowID == rhs.windowID &&
            lhs.ownerProcessIdentifier == rhs.ownerProcessIdentifier &&
            lhs.ownerProcessStartIdentity == rhs.ownerProcessStartIdentity &&
            lhs.capturedBounds == rhs.capturedBounds
    }
}
