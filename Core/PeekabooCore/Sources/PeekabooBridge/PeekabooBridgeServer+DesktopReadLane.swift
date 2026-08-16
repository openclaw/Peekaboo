import CoreGraphics
import Foundation
import PeekabooAutomationKit

private enum DesktopReadLaneResolution {
    case lane(scope: DesktopOperationScope, access: DesktopOperationAccess, validatesIdentity: Bool)
    case exactIdentityUnavailable
}

extension PeekabooBridgeServer {
    func validatedDesktopReadOperationLane(
        for request: PeekabooBridgeRequest,
        proposed: (scope: DesktopOperationScope, access: DesktopOperationAccess))
        -> (scope: DesktopOperationScope, access: DesktopOperationAccess)
    {
        switch self.desktopReadLaneResolution(for: request, proposed: proposed) {
        case let .lane(scope, access, validatesIdentity):
            if validatesIdentity, !self.desktopReadScopeIsCurrent(scope) {
                return (.global, .write)
            }
            return (scope, access)
        case .exactIdentityUnavailable:
            return (.global, .write)
        }
    }

    func withValidatedDesktopReadOperationLane<T: Sendable>(
        for request: PeekabooBridgeRequest,
        proposed: (scope: DesktopOperationScope, access: DesktopOperationAccess),
        operation: () async throws -> T) async throws -> T
    {
        try await self.withValidatedDesktopReadOperationLane(
            for: request,
            proposed: proposed)
        { _ in
            try await operation()
        }
    }

    private func withValidatedDesktopReadOperationLane<T: Sendable>(
        for request: PeekabooBridgeRequest,
        proposed: (scope: DesktopOperationScope, access: DesktopOperationAccess),
        operation: (DesktopOperationScope) async throws -> T) async throws -> T
    {
        let resolution = self.desktopReadLaneResolution(for: request, proposed: proposed)
        guard case let .lane(scope, access, validatesIdentity) = resolution else {
            throw Self.exactDesktopReadTargetChangedError()
        }
        return try await self.desktopOperationLaneCoordinator.run(scope: scope, access: access) {
            try PeekabooBridgeRequestContext.checkRequestIsActive()
            if validatesIdentity, !self.desktopReadScopeIsCurrent(scope) {
                throw Self.exactDesktopReadTargetChangedError()
            }
            let result = try await operation(scope)
            try PeekabooBridgeRequestContext.checkRequestIsActive()
            if validatesIdentity, !self.desktopReadScopeIsCurrent(scope) {
                throw Self.exactDesktopReadTargetChangedError()
            }
            return result
        }
    }

    private func desktopReadLaneResolution(
        for request: PeekabooBridgeRequest,
        proposed: (scope: DesktopOperationScope, access: DesktopOperationAccess)) -> DesktopReadLaneResolution
    {
        let plan = PeekabooBridgeOperationResultSemantics.semanticPlan(for: request)
        if let exactTarget = plan.exactReadTarget,
           let exactScope = self.exactDesktopReadScope(for: exactTarget)
        {
            return .lane(scope: exactScope, access: .read, validatesIdentity: true)
        }
        if plan.exactReadTarget != nil {
            return .exactIdentityUnavailable
        }
        return .lane(scope: proposed.scope, access: proposed.access, validatesIdentity: false)
    }

    private func exactDesktopReadScope(
        for target: PeekabooBridgeOperationResultSemantics.ExactReadTarget) -> DesktopOperationScope?
    {
        switch target {
        case let .process(processIdentifier):
            return self.currentExactProcessReadScope(processIdentifier: processIdentifier)
        case let .window(rawWindowID, expectedOwner):
            guard let windowID = CGWindowID(exactly: rawWindowID),
                  case let .window(identity)? = self.currentExactWindowReadScope(windowID: windowID),
                  expectedOwner.map({ $0 == identity.ownerProcessIdentifier }) ?? true
            else {
                return nil
            }
            return .window(identity)
        case let .validatedWindow(identity):
            return .window(identity)
        }
    }

    private func currentExactProcessReadScope(processIdentifier: pid_t) -> DesktopOperationScope? {
        guard processIdentifier > 0,
              let processStartIdentity = self.processStartIdentityProvider(processIdentifier),
              self.processStartIdentityProvider(processIdentifier) == processStartIdentity
        else {
            return nil
        }
        return .process(ApplicationProcessIdentity(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity))
    }

    private func currentExactWindowReadScope(windowID: CGWindowID) -> DesktopOperationScope? {
        guard windowID != kCGNullWindowID,
              let ownerProcessIdentifier = self.windowOwnerProcessIdentifierProvider(windowID),
              ownerProcessIdentifier > 0,
              let bounds = self.windowBoundsProvider(windowID),
              let processStartIdentity = self.processStartIdentityProvider(ownerProcessIdentifier),
              self.windowOwnerProcessIdentifierProvider(windowID) == ownerProcessIdentifier,
              self.windowBoundsProvider(windowID) == bounds,
              self.processStartIdentityProvider(ownerProcessIdentifier) == processStartIdentity
        else {
            return nil
        }
        return .window(WindowMutationIdentity(
            windowID: Int(windowID),
            ownerProcessIdentifier: ownerProcessIdentifier,
            ownerProcessStartIdentity: processStartIdentity,
            capturedBounds: bounds))
    }

    private func desktopReadScopeIsCurrent(_ scope: DesktopOperationScope) -> Bool {
        switch scope {
        case .global:
            return true
        case let .process(identity):
            return self.processStartIdentityProvider(identity.processIdentifier) == identity.processStartIdentity
        case let .window(identity):
            guard let windowID = CGWindowID(exactly: identity.windowID),
                  let capturedBounds = identity.capturedBounds
            else {
                return false
            }
            return self.windowOwnerProcessIdentifierProvider(windowID) == identity.ownerProcessIdentifier &&
                self.windowBoundsProvider(windowID) == capturedBounds &&
                self.processStartIdentityProvider(identity.ownerProcessIdentifier) ==
                identity.ownerProcessStartIdentity
        }
    }

    private static func exactDesktopReadTargetChangedError() -> PeekabooBridgeErrorEnvelope {
        PeekabooBridgeErrorEnvelope(
            code: .invalidRequest,
            message: "The exact desktop read target changed owner, process generation, or bounds before completion")
    }
}
